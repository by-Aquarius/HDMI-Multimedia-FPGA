using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.IO;
using System.IO.Ports;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Microsoft.Win32;

namespace MediaTerminalControl
{
    internal sealed class BoardBusyException : IOException { public BoardBusyException() : base("板端正在处理任务或显示紧急通知，请稍后重试或结束插播。") {} }

    // 固定帧协议；所有请求通过同一个锁串行发送，避免状态轮询插入字幕上传。
    internal sealed class BoardLink : IDisposable
    {
        private readonly SerialPort port;
        private readonly SemaphoreSlim gate = new SemaphoreSlim(1, 1);
        private byte sequence;
        public BoardLink(string name)
        {
            port = new SerialPort(name, 115200, Parity.None, 8, StopBits.One);
            port.ReadTimeout = 2500; port.WriteTimeout = 2500;
            port.DtrEnable = false; port.RtsEnable = false;
            port.Open(); port.DiscardInBuffer();
        }
        public static ushort Crc(byte[] bytes, int offset, int count)
        {
            ushort crc = 0xffff;
            for (int i = offset; i < offset + count; i++)
            {
                crc ^= (ushort)(bytes[i] << 8);
                for (int b = 0; b < 8; b++) crc = (ushort)((crc << 1) ^ ((crc & 0x8000) != 0 ? 0x1021 : 0));
            }
            return crc;
        }
        public static byte[] Frame(byte cmd, byte seq, ushort address, ushort data)
        {
            byte[] f = { 0xa5, 0x5a, cmd, seq, (byte)address, (byte)(address >> 8), (byte)data, (byte)(data >> 8), 0, 0 };
            ushort crc = Crc(f, 2, 6); f[8] = (byte)crc; f[9] = (byte)(crc >> 8); return f;
        }
        private byte[] Exchange(byte cmd, ushort address, ushort data)
        {
            byte seq = ++sequence; byte[] f = Frame(cmd, seq, address, data);
            port.Write(f, 0, f.Length);
            DateTime end = DateTime.UtcNow.AddSeconds(3);
            int position = 0; byte[] reply = new byte[10];
            while (DateTime.UtcNow < end)
            {
                int n = port.ReadByte();
                if (position == 0 && n != 0xa5) continue;
                if (position == 1 && n != 0x5a) { position = n == 0xa5 ? 1 : 0; continue; }
                reply[position++] = (byte)n;
                if (position != 10) continue;
                position = 0;
                if (Crc(reply, 2, 6) != (ushort)(reply[8] | reply[9] << 8)) continue;
                if (reply[2] != (byte)(cmd | 0x80) || reply[3] != seq) continue;
                if(cmd>=0x10 && reply[6]!=0) {
                    if(reply[6]==2) throw new BoardBusyException();
                    string message=reply[6]==1 ? "参数不受支持，请检查输入。" : reply[6]==3 ? "文字接收不完整，请重新发送。" : reply[6]==4 ? "板端提交超时，当前显示状态未确认。" : reply[6]==5 ? "当前字库不支持部分字符，请改用常用简体字。" : "板端未接受本次操作。";
                    throw new IOException(message);
                }
                return reply;
            }
            throw new TimeoutException("板端未应答，请检查连接与配套位流。按键命令未自动重发。");
        }
        public async Task<byte[]> Request(byte cmd, ushort data)
        {
            await gate.WaitAsync();
            try { return await Task.Run(() => Exchange(cmd, 0, data)); }
            finally { gate.Release(); }
        }
        public async Task Upload(string text, bool urgent, int seconds, Action<int> progress)
        {
            if(String.IsNullOrWhiteSpace(text) || text.Length>64) throw new ArgumentException("字幕需为 1 到 64 字。");
            string repertoire=File.ReadAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"font_characters.txt"));
            foreach(char c in text) if(repertoire.IndexOf(c)<0) throw new ArgumentException("当前字库不支持字符："+c+"。请换用常用简体字。");
            await gate.WaitAsync();
            try {
                await Task.Run(() => {
                    for(int attempt=0;;attempt++) {
                        try { Exchange(0x20,(ushort)(urgent ? ((seconds<<8)|1) : 0),(ushort)text.Length);break; }
                        catch(BoardBusyException) {if(attempt>=4)throw;Thread.Sleep(20);}
                    }
                    for(int index=0;index<text.Length;index++) {
                        byte[] frame=Frame(0x21,++sequence,(ushort)index,(ushort)text[index]);
                        port.Write(frame,0,frame.Length); progress((index+1)*100/text.Length);
                    }
                    Exchange(0x22,0,1); progress(100);
                });
            } finally {gate.Release();}
        }
        public void Dispose() { port.Dispose(); }
    }

    internal sealed class MainWindow : Form
    {
        private readonly ComboBox ports = new ComboBox();
        private readonly Button connect = new Button();
        private readonly Button promptSwitch = new Button();
        private readonly Button audioMode = new Button();
        private bool promptSupported;
        private bool audioModeSupported, perImageAudioMode;
        private readonly Label connection = new Label(), imageState = new Label(), playbackState = new Label();
        private readonly Label volumeState = new Label(), detailState = new Label(), note = new Label();
        private readonly TextBox subtitle = new TextBox();
        private readonly Label preview = new Label();
        private readonly NumericUpDown noticeSeconds = new NumericUpDown();
        private readonly NumericUpDown volume = new NumericUpDown();
        private readonly List<Control> boardControls = new List<Control>();
        private readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        private BoardLink link;
        private bool working, polling, closing;
        private int pollErrors;
        private readonly Font body = new Font("Microsoft YaHei UI", 10), heading = new Font("Microsoft YaHei UI", 15, FontStyle.Bold);
        public MainWindow()
        {
            Text = "多媒体终端控制";
            ClientSize = new Size(1080, 960);
            MinimumSize = new Size(660, 480);
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;
            BackColor = Color.White;
            ForeColor = Color.Black;
            Font = body;
            StartPosition = FormStartPosition.CenterScreen;
            DoubleBuffered = true;
            SuspendLayout();

            TableLayoutPanel layout = new TableLayoutPanel();
            layout.Dock = DockStyle.Fill;
            layout.BackColor = Color.White;
            layout.ColumnCount = 1;
            layout.RowCount = 18;
            layout.Padding = new Padding(28, 18, 28, 16);
            layout.Margin = Padding.Empty;
            layout.AutoScroll = true;
            layout.AutoScrollMinSize = new Size(760, 650);
            layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
            AddRow(layout, SizeType.Absolute, 46F);
            AddRow(layout, SizeType.Absolute, 28F);
            AddRow(layout, SizeType.Absolute, 17F);
            AddRow(layout, SizeType.Absolute, 42F);
            AddRow(layout, SizeType.Absolute, 17F);
            AddRow(layout, SizeType.Absolute, 34F);
            AddRow(layout, SizeType.Absolute, 46F);
            AddRow(layout, SizeType.Absolute, 46F);
            AddRow(layout, SizeType.Absolute, 17F);
            AddRow(layout, SizeType.Absolute, 32F);
            AddRow(layout, SizeType.Absolute, 40F);
            AddRow(layout, SizeType.Absolute, 54F);
            AddRow(layout, SizeType.Absolute, 46F);
            AddRow(layout, SizeType.Absolute, 46F);
            AddRow(layout, SizeType.Absolute, 17F);
            AddRow(layout, SizeType.Absolute, 50F);
            AddRow(layout, SizeType.Percent, 100F);
            AddRow(layout, SizeType.Absolute, 28F);

            layout.Controls.Add(TextLabel("多媒体终端", heading), 0, 0);
            layout.Controls.Add(TextLabel("串口控制 / 字幕编辑", body), 0, 1);
            layout.Controls.Add(Separator(), 0, 2);

            TableLayoutPanel connectionRow = Grid(
                FixedColumn(52), PercentColumn(45), FixedColumn(88), FixedColumn(96), PercentColumn(55));
            connectionRow.Controls.Add(TextLabel("连接", body), 0, 0);
            ports.DropDownStyle = ComboBoxStyle.DropDownList;
            ports.FlatStyle = FlatStyle.Flat;
            ports.Dock = DockStyle.Fill;
            ports.Margin = new Padding(2, 5, 10, 5);
            connectionRow.Controls.Add(ports, 1, 0);
            connectionRow.Controls.Add(ActionButton("刷新", delegate { RefreshPorts(); }, false), 2, 0);
            connect.Text = "连接";
            Style(connect);
            connect.Dock = DockStyle.Fill;
            connect.Margin = new Padding(4, 4, 4, 4);
            connect.Click += async delegate { await Connect(); };
            connectionRow.Controls.Add(connect, 3, 0);
            connection.Text = "未连接";
            connection.AutoEllipsis = true;
            LabelStyle(connection);
            connection.Margin = new Padding(10, 0, 0, 0);
            connectionRow.Controls.Add(connection, 4, 0);
            layout.Controls.Add(connectionRow, 0, 3);
            layout.Controls.Add(Separator(), 0, 4);

            TableLayoutPanel statusRow = Grid(PercentColumn(24), PercentColumn(23), PercentColumn(28), PercentColumn(25));
            imageState.Text = "图片  — / —";
            playbackState.Text = "播放状态  —";
            volumeState.Text = "音量  — / 10";
            foreach (Label status in new[] { imageState, playbackState, volumeState })
            {
                LabelStyle(status);
                status.AutoEllipsis = true;
                statusRow.Controls.Add(status);
            }
            audioMode.Text = "音频模式：待连接";
            Style(audioMode);
            audioMode.Dock = DockStyle.Fill;
            audioMode.Margin = new Padding(4, 4, 4, 4);
            audioMode.Click += async delegate { await SetAudioMode((byte)(perImageAudioMode ? 0 : 1)); };
            statusRow.Controls.Add(audioMode, 3, 0);
            boardControls.Add(audioMode);
            layout.Controls.Add(statusRow, 0, 5);

            TableLayoutPanel mediaRow = Grid(
                PercentColumn(14), PercentColumn(18), PercentColumn(14), PercentColumn(14),
                FixedColumn(18), FixedColumn(60), FixedColumn(72), FixedColumn(84), FixedColumn(88));
            mediaRow.Controls.Add(ActionButton("上一张", async delegate { await Key(11); }), 0, 0);
            mediaRow.Controls.Add(ActionButton("播放 / 暂停", async delegate { await Key(10); }), 1, 0);
            mediaRow.Controls.Add(ActionButton("下一张", async delegate { await Key(9); }), 2, 0);
            mediaRow.Controls.Add(ActionButton("节目模式", async delegate { await Key(2); }), 3, 0);
            mediaRow.Controls.Add(TextLabel("音量", body, ContentAlignment.MiddleCenter), 5, 0);
            volume.Minimum = 0;
            volume.Maximum = 10;
            volume.Value = 8;
            volume.BorderStyle = BorderStyle.FixedSingle;
            volume.Dock = DockStyle.Fill;
            volume.Margin = new Padding(4, 6, 4, 6);
            mediaRow.Controls.Add(volume, 6, 0);
            boardControls.Add(volume);
            mediaRow.Controls.Add(ActionButton("设置", async delegate { await Command(0x11, (ushort)volume.Value, "音量目标已发送，以下方板端状态为准"); }), 7, 0);
            mediaRow.Controls.Add(ActionButton("静音", async delegate { volume.Value = 0; await Command(0x11, 0, "静音目标已发送"); }), 8, 0);
            layout.Controls.Add(mediaRow, 0, 6);

            TableLayoutPanel detailRow = Grid(
                PercentColumn(19), PercentColumn(19), PercentColumn(19), PercentColumn(19), PercentColumn(24));
            detailRow.Controls.Add(ActionButton("轮播慢一档", async delegate { await Key(12); }), 0, 0);
            detailRow.Controls.Add(ActionButton("轮播快一档", async delegate { await Key(13); }), 1, 0);
            detailRow.Controls.Add(ActionButton("亮度 −", async delegate { await Key(14); }), 2, 0);
            detailRow.Controls.Add(ActionButton("亮度 ＋", async delegate { await Key(15); }), 3, 0);
            detailState.Text = "亮度 —    速度 —";
            detailState.AutoEllipsis = true;
            LabelStyle(detailState);
            detailState.Margin = new Padding(10, 0, 0, 0);
            detailRow.Controls.Add(detailState, 4, 0);
            layout.Controls.Add(detailRow, 0, 7);
            layout.Controls.Add(Separator(), 0, 8);

            TableLayoutPanel subtitleHeading = Grid(PercentColumn(16), PercentColumn(84));
            subtitleHeading.Controls.Add(TextLabel("字幕", body), 0, 0);
            subtitleHeading.Controls.Add(TextLabel("常用中文、英文和数字 · 最多 64 字 · 底部滚动字幕", body), 1, 0);
            layout.Controls.Add(subtitleHeading, 0, 9);

            subtitle.BorderStyle = BorderStyle.FixedSingle;
            subtitle.MaxLength = 64;
            subtitle.Text = "欢迎使用多媒体展示终端";
            subtitle.Dock = DockStyle.Fill;
            subtitle.Margin = new Padding(0, 4, 0, 4);
            subtitle.TextChanged += delegate { UpdatePreview(); };
            layout.Controls.Add(subtitle, 0, 10);

            preview.BackColor = Color.White;
            preview.ForeColor = Color.Black;
            preview.BorderStyle = BorderStyle.FixedSingle;
            preview.TextAlign = ContentAlignment.MiddleLeft;
            preview.Dock = DockStyle.Fill;
            preview.Margin = new Padding(0, 3, 0, 3);
            layout.Controls.Add(preview, 0, 11);

            TableLayoutPanel subtitleActions = Grid(
                PercentColumn(20), PercentColumn(20), PercentColumn(20), PercentColumn(20), PercentColumn(20));
            subtitleActions.Controls.Add(ActionButton("发送字幕", async delegate { await SendSubtitle(false); }), 0, 0);
            subtitleActions.Controls.Add(ActionButton("恢复中文轮播", async delegate { await Command(0x23, 0, "已恢复内置中文轮播"); }), 1, 0);
            promptSwitch.Text = "换图语音：待连接";
            Style(promptSwitch);
            promptSwitch.Dock = DockStyle.Fill;
            promptSwitch.Margin = new Padding(4, 4, 4, 4);
            promptSwitch.Click += async delegate { await Command(0x10,3,"已切换换图语音提示；也可短按 KEY3"); await Poll(); };
            subtitleActions.Controls.Add(promptSwitch, 2, 0);
            boardControls.Add(promptSwitch);
            subtitleActions.Controls.Add(ActionButton("导入文本", delegate { ImportText(); }, false), 3, 0);
            subtitleActions.Controls.Add(ActionButton("保存文本", delegate { SaveText(); }, false), 4, 0);
            layout.Controls.Add(subtitleActions, 0, 12);

            TableLayoutPanel emergencyRow = Grid(
                PercentColumn(22), PercentColumn(22), PercentColumn(11), PercentColumn(8), PercentColumn(37));
            emergencyRow.Controls.Add(ActionButton("紧急插播", async delegate { await SendSubtitle(true); }), 0, 0);
            emergencyRow.Controls.Add(ActionButton("结束插播", async delegate { await Command(0x24,0,"已结束插播，恢复原节目与字幕"); }), 1, 0);
            emergencyRow.Controls.Add(TextLabel("持续时间", body), 2, 0);
            noticeSeconds.Minimum = 1;
            noticeSeconds.Maximum = 120;
            noticeSeconds.Value = 10;
            noticeSeconds.Dock = DockStyle.Fill;
            noticeSeconds.Margin = new Padding(4, 6, 4, 6);
            emergencyRow.Controls.Add(noticeSeconds, 3, 0);
            boardControls.Add(noticeSeconds);
            emergencyRow.Controls.Add(TextLabel("秒 · 结束后恢复原节目", body), 4, 0);
            layout.Controls.Add(emergencyRow, 0, 13);
            layout.Controls.Add(Separator(), 0, 14);

            note.Text = "连接板上的 UART-USB 接口，选择对应 COM 口。";
            note.AutoEllipsis = true;
            LabelStyle(note);
            layout.Controls.Add(note, 0, 15);
            layout.Controls.Add(new Panel(), 0, 16);
            layout.Controls.Add(TextLabel("115200 baud · 8N1", body), 0, 17);

            BuildModernLayout(layout);
            ResumeLayout(true);
            timer.Interval = 600; timer.Tick += async delegate { if (link != null && !working && !polling) await Poll(); }; timer.Start();
            FormClosing += delegate { closing = true; timer.Stop(); if (link != null) link.Dispose(); try { File.WriteAllText(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"subtitle.txt"),subtitle.Text,System.Text.Encoding.UTF8); } catch(IOException) { } catch(UnauthorizedAccessException) { } };
            try { string saved=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"subtitle.txt"); if(File.Exists(saved)) {string text=File.ReadAllText(saved); subtitle.Text=text.Substring(0,Math.Min(64,text.Length));} } catch(IOException) { } catch(UnauthorizedAccessException) { }
            RefreshPorts(); SetControls(false); UpdatePreview();
        }
        private void BuildModernLayout(TableLayoutPanel old)
        {
            BackColor = Color.FromArgb(241,245,249);
            ForeColor = Color.FromArgb(30,41,59);
            Panel scroll = new Panel { Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(20) };
            Panel page = new Panel();
            page.Controls.Add(new Label { Text = "多媒体终端", Font = heading, AutoSize = true, Margin = new Padding(4,0,0,6) });
            page.Controls.Add(new Label { Text = "设备控制台  /  R298", AutoSize = true, ForeColor = Color.SlateGray, Margin = new Padding(4,0,0,16) });
            AddCard(page,"设备连接", new Control[] { old.GetControlFromPosition(0,3) });
            AddCard(page,"播放控制与音量", new Control[] { old.GetControlFromPosition(0,5), old.GetControlFromPosition(0,6) });
            AddCard(page,"亮度与轮播速度", new Control[] { old.GetControlFromPosition(0,7) });
            AddCard(page,"字幕编辑 · 最多 64 字", new Control[] { subtitle, preview, old.GetControlFromPosition(0,12) });
            AddCard(page,"紧急插播", new Control[] { old.GetControlFromPosition(0,13) });
            note.MinimumSize = new Size(0,54); note.Dock = DockStyle.Top; note.Padding = new Padding(8); page.Controls.Add(note);
            page.Controls.Add(new Label { Text = "UART-USB  ·  115200 baud  ·  8N1", AutoSize = true, ForeColor = Color.SlateGray });
            scroll.Controls.Add(page); Controls.Add(scroll); scroll.SizeChanged += delegate { ArrangePage(page,scroll); }; Shown += delegate { ArrangePage(page,scroll); };
            old.Dispose();
        }
        private void ArrangePage(Panel page, Panel scroll)
        {
            page.SuspendLayout(); page.AutoSize = false; page.Dock = DockStyle.None;
            page.Location = new Point(20 + scroll.AutoScrollPosition.X,20 + scroll.AutoScrollPosition.Y); page.Width = Math.Max(540, scroll.ClientSize.Width - 48);
            int y=0;
            foreach(Control item in page.Controls)
            {
                item.Dock=DockStyle.None; item.Left=0; item.Top=y; item.Width=page.Width;
                Panel card=item as Panel;
                if(card!=null)
                {
                    card.AutoSize=false; int cy=14;
                    var ordered = new List<Control>(); foreach(Control child in card.Controls) ordered.Add(child); ordered.Sort(delegate(Control a,Control b) { return Convert.ToInt32(a.Tag).CompareTo(Convert.ToInt32(b.Tag)); }); foreach(Control row in ordered)
                    {
                        row.Dock=DockStyle.None; row.Left=14; row.Top=cy; row.Width=card.Width-28;
                        FlowLayoutPanel flow=row as FlowLayoutPanel;
                        if(flow!=null) { flow.AutoSize=false; flow.Height=flow.GetPreferredSize(new Size(flow.Width,0)).Height; }
                        else if(row is Label && row!=preview) row.Height=30;
                        cy+=row.Height+8;
                    }
                    card.Height=cy+6;
                }
                y+=item.Height+12;
            }
            page.Height=y; scroll.AutoScrollMinSize = new Size(0,y+40); page.ResumeLayout(false);
        }
        private void AddCard(Panel page, string caption, Control[] rows)
        {
            Panel card = new Panel { BackColor = Color.White };
            card.Controls.Add(new Label { Text = caption, AutoSize = true, Font = new Font(body,FontStyle.Bold), ForeColor = Color.FromArgb(30,64,110), Margin = new Padding(4,0,0,8) });
            int order=1; foreach(Control row in rows)
            {
                TableLayoutPanel grid = row as TableLayoutPanel;
                if(grid != null)
                {
                    FlowLayoutPanel flow = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Top, WrapContents = true, Margin = Padding.Empty };
                    flow.AutoSizeMode = AutoSizeMode.GrowAndShrink; var children = new List<Control>(); foreach(Control c in grid.Controls) children.Add(c);
                    foreach(Control c in children)
                    {
                        c.Dock = DockStyle.None; c.Anchor = AnchorStyles.Left | AnchorStyles.Top;
                        c.Margin = new Padding(4,4,8,6);
                        if(c is Button) { c.AutoSize = true; c.MinimumSize = new Size(120,40); c.Padding = new Padding(12,5,12,5); Style((Button)c); }
                        else if(c is ComboBox) c.Width = 180;
                        else if(c is NumericUpDown) c.Width = 86;
                        else if(c is Label) { c.AutoSize = true; c.MinimumSize = new Size(0,36); c.Padding = new Padding(0,7,0,0); }
                        flow.Controls.Add(c);
                    }
                    flow.Tag=order++; card.Controls.Add(flow);
                }
                else
                {
                    row.Dock = DockStyle.Top; row.Margin = new Padding(4,4,4,8);
                    row.MinimumSize = new Size(0,row == preview ? 54 : 36);
                    if(row == preview) { row.Padding = new Padding(12,8,12,8); row.BackColor = Color.FromArgb(239,246,255); }
                    row.Tag=order++; card.Controls.Add(row);
                }
            }
            page.Controls.Add(card);
        }
        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);
            Rectangle area = Screen.FromControl(this).WorkingArea;
            int maxWidth = Math.Max(640, area.Width - 48);
            int maxHeight = Math.Max(600, area.Height - 72);
            MinimumSize = new Size(Math.Min(MinimumSize.Width, maxWidth), Math.Min(MinimumSize.Height, maxHeight));
            int width = Math.Min(Width, maxWidth);
            int height = Math.Min(Height, maxHeight);
            Bounds = new Rectangle(
                area.Left + Math.Max(0, (area.Width - width) / 2),
                area.Top + Math.Max(0, (area.Height - height) / 2),
                width,
                height);
        }
        private static void AddRow(TableLayoutPanel table, SizeType type, float height)
        {
            table.RowStyles.Add(new RowStyle(type, height));
        }
        private static ColumnStyle PercentColumn(float width)
        {
            return new ColumnStyle(SizeType.Percent, width);
        }
        private static ColumnStyle FixedColumn(int width)
        {
            return new ColumnStyle(SizeType.Absolute, width);
        }
        private static TableLayoutPanel Grid(params ColumnStyle[] columns)
        {
            TableLayoutPanel table = new TableLayoutPanel();
            table.Dock = DockStyle.Fill;
            table.BackColor = Color.White;
            table.Margin = Padding.Empty;
            table.Padding = Padding.Empty;
            table.ColumnCount = columns.Length;
            table.RowCount = 1;
            table.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
            foreach (ColumnStyle column in columns) table.ColumnStyles.Add(column);
            return table;
        }
        private static Label TextLabel(string text, Font font, ContentAlignment alignment)
        {
            Label label = new Label();
            label.Text = text;
            label.Font = font;
            label.TextAlign = alignment;
            label.AutoSize = false;
            label.Dock = DockStyle.Fill;
            label.Margin = Padding.Empty;
            return label;
        }
        private static Label TextLabel(string text, Font font)
        {
            return TextLabel(text, font, ContentAlignment.MiddleLeft);
        }
        private static void LabelStyle(Label label)
        {
            label.AutoSize = false;
            label.Dock = DockStyle.Fill;
            label.TextAlign = ContentAlignment.MiddleLeft;
            label.Margin = Padding.Empty;
        }
        private static Panel Separator()
        {
            Panel line = new Panel();
            line.BackColor = Color.Black;
            line.Dock = DockStyle.Fill;
            line.Margin = new Padding(0, 8, 0, 8);
            return line;
        }
        private Button ActionButton(string text, EventHandler click, bool board = true)
        {
            Button button = new Button();
            button.Text = text;
            Style(button);
            button.Dock = DockStyle.Fill;
            button.Margin = new Padding(4, 4, 4, 4);
            button.Click += click;
            if (board) boardControls.Add(button);
            return button;
        }
        private void Style(Button b) { b.FlatStyle = FlatStyle.Flat; b.FlatAppearance.BorderSize = 1; b.FlatAppearance.BorderColor = Color.FromArgb(203,213,225); b.BackColor = Color.FromArgb(248,250,252); b.ForeColor = Color.FromArgb(30,64,110); b.Cursor = Cursors.Hand; b.UseVisualStyleBackColor = false; }
        private void SetControls(bool enabled) { foreach(Control c in boardControls) c.Enabled = enabled; promptSwitch.Enabled=enabled && promptSupported; audioMode.Enabled=enabled && audioModeSupported; }
        private void RefreshPorts()
        {
            string old=ports.Text, preferred=null; ports.Items.Clear(); string[] names=SerialPort.GetPortNames();
            Array.Sort(names,delegate(string a,string b) { int av,bv; return Int32.TryParse(a.Substring(3),out av) && Int32.TryParse(b.Substring(3),out bv) ? av.CompareTo(bv) : String.Compare(a,b,StringComparison.OrdinalIgnoreCase); });
            try {
                using(RegistryKey usb=Registry.LocalMachine.OpenSubKey(@"SYSTEM\CurrentControlSet\Enum\USB"))
                if(usb!=null)foreach(string hardware in usb.GetSubKeyNames())if(hardware.StartsWith("VID_1A86",StringComparison.OrdinalIgnoreCase))
                using(RegistryKey model=usb.OpenSubKey(hardware))foreach(string instance in model.GetSubKeyNames())
                using(RegistryKey settings=model.OpenSubKey(instance+@"\Device Parameters"))
                { string candidate=settings==null ? null : settings.GetValue("PortName") as string; if(Array.IndexOf(names,candidate)>=0)preferred=candidate; }
            } catch(System.Security.SecurityException) { }
            ports.Items.AddRange(names);
            if(names.Length>0)ports.SelectedIndex=Array.IndexOf(names,old)>=0 ? Array.IndexOf(names,old) : preferred!=null ? Array.IndexOf(names,preferred) : 0;
        }
        private async Task Connect()
        {
            if (working || polling) return;
            if (link != null) { link.Dispose(); link=null; connect.Text="连接"; connection.Text="未连接"; SetControls(false); return; }
            if (ports.SelectedItem == null) { note.Text="未发现 COM 口，请接入板上 UART-USB 接口后刷新。"; return; }
            working=true; connect.Enabled=false;
            try { link=new BoardLink(ports.Text); byte[] r=await link.Request(2,0); promptSupported=false; audioModeSupported=false; if(r[7]!=4) throw new IOException("请使用协议 4 的配套字符字幕位流"); connection.Text=ports.Text+" 已连接"; connect.Text="断开"; pollErrors=0; SetControls(true); note.Text="已连接。B10 控制底部字幕显示，关闭后保留已上传文字。"; }
            catch(Exception e) { if(link!=null)link.Dispose(); link=null; connection.Text="连接失败"; SetControls(false); note.Text=e.Message; }
            finally { working=false; connect.Enabled=true; }
            if(link!=null) await Poll();
        }
        private async Task Poll()
        {
            polling=true;
            try {
                byte[] r=await link.Request(1,0); pollErrors=0;
                int state=r[6]>>5, vol=r[6]&31; int flags=r[7];
                imageState.Text="图片  "+(r[5]==0?"—":(r[4]+1).ToString())+" / "+r[5];
                playbackState.Text=(flags&64)!=0 ? "状态  紧急通知" : (flags&16)!=0 ? "状态  节目模式" : "状态  "+((flags&8)!=0?"错误":(flags&4)!=0?"切换中":(flags&2)!=0?"暂停":(flags&1)!=0?"播放":"保持");
                volumeState.Text="音量  "+vol+" / 10"; connection.Text=ports.Text+" 已连接";
                byte[] prompt=await link.Request(0x0a,0); promptSupported=prompt[7]==0x53;
                promptSwitch.Text=promptSupported ? "换图语音："+((prompt[4]&1)!=0?"开":"关")+((prompt[4]&4)!=0?" · 播报中":"") : "换图语音：需 R291 位流";
                promptSwitch.Enabled=promptSupported && !working;
                byte[] audio=await link.Request(0x0f,0); audioModeSupported=(audio[2]==0x8f && audio[7]==0xa3); perImageAudioMode=(audio[4]&1)!=0;
                audioMode.Text=audioModeSupported ? "音频："+(perImageAudioMode?"逐视频":"统一") : "音频模式：需 R298";
                audioMode.Enabled=audioModeSupported && !working;
                byte[] d=await link.Request(2,0); detailState.Text="亮度 "+d[4]+" / 10    速度档 "+d[5]+(d[6]!=0?"    E"+d[6]:"");
            } catch(Exception e) { if(!closing) { connection.Text="通信超时 / 状态未更新"; note.Text=e.Message; if(++pollErrors>=3) { link.Dispose(); link=null; SetControls(false); connect.Text="连接"; } } }
            finally { polling=false; }
        }
        private async Task Key(byte key) { await Command(0x10,key,"操作已发送，等待板端状态更新"); }
        private async Task SetAudioMode(byte mode)
        {
            await Command(0x13,mode,mode==0 ? "已切换为统一音频模式" : "已切换为逐视频音频模式");
            if(link!=null) await Poll();
        }
        private async Task Command(byte command, ushort data, string message)
        {
            if(link==null || working) return; working=true; SetControls(false); connect.Enabled=false;
            try { await link.Request(command,data); note.Text=message; }
            catch(Exception e) { note.Text=e.Message; }
            finally { working=false; connect.Enabled=true; SetControls(link!=null); }
        }
        private void UpdatePreview() { preview.Text=subtitle.Text; }
        private async Task SendSubtitle(bool urgent)
        {
            if(link==null || working) return;
            if(String.IsNullOrWhiteSpace(subtitle.Text)) {note.Text="请填写字幕，或恢复中文轮播。";return;}
            working=true;SetControls(false);connect.Enabled=false;
            try {
                await link.Upload(subtitle.Text,urgent,(int)noticeSeconds.Value,percent=> {if(!closing)BeginInvoke(new Action(()=>note.Text="发送文字  "+percent+"%"));});
                byte[] status=await link.Request(1,0);
                note.Text=(status[7]&32)!=0 ? (urgent ? "紧急通知已发布，到时恢复原节目。" : "底部滚动字幕已更新。") : "文字已保存，打开 B10 后显示。";
            } catch(Exception e) {note.Text="字幕未确认显示："+e.Message;}
            finally {working=false;connect.Enabled=true;SetControls(link!=null);}
        }
        private void ImportText() { using(OpenFileDialog d=new OpenFileDialog()) { d.Filter="文本文件|*.txt"; if(d.ShowDialog()==DialogResult.OK) try { string text=File.ReadAllText(d.FileName).Replace("\r", " ").Replace("\n"," "); subtitle.Text=text.Substring(0,Math.Min(64,text.Length)); } catch(Exception e) { note.Text=e.Message; } } }
        private void SaveText() { using(SaveFileDialog d=new SaveFileDialog()) { d.Filter="文本文件|*.txt"; d.FileName="字幕.txt"; if(d.ShowDialog()==DialogResult.OK) try { File.WriteAllText(d.FileName,subtitle.Text,System.Text.Encoding.UTF8); note.Text="文本已保存"; } catch(Exception e) { note.Text=e.Message; } } }
        [STAThread]
        private static void Main(string[] args)
        {
            EnableBestDpiAwareness();
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            using(MainWindow window=new MainWindow()) {
                if(args.Length==2 && args[0]=="--preview") { window.Opacity=0; window.Show(); Application.DoEvents(); using(Bitmap b=new Bitmap(window.Width,window.Height)) { window.DrawToBitmap(b,new Rectangle(0,0,b.Width,b.Height)); b.Save(args[1]); } window.Hide(); return; }
                if(args.Length==3 && args[0]=="--preview-connected") {
                    window.Opacity=0;
                    window.Shown+=async delegate {
                        int index=window.ports.Items.IndexOf(args[2]); if(index>=0)window.ports.SelectedIndex=index;
                        await window.Connect();
                        using(Bitmap b=new Bitmap(window.Width,window.Height)) { window.DrawToBitmap(b,new Rectangle(0,0,b.Width,b.Height)); b.Save(args[1]); }
                        window.Close();
                    };
                }
                if(args.Length==2 && args[0]=="--connect") window.Shown+=async delegate { int index=window.ports.Items.IndexOf(args[1]); if(index>=0)window.ports.SelectedIndex=index; await window.Connect(); };
                Application.Run(window);
            }
        }
        [DllImport("user32.dll")]
        private static extern bool SetProcessDpiAwarenessContext(IntPtr dpiContext);
        [DllImport("user32.dll")]
        private static extern bool SetProcessDPIAware();
        private static void EnableBestDpiAwareness()
        {
            try
            {
                if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return;
            }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
            try { SetProcessDPIAware(); }
            catch (DllNotFoundException) { }
            catch (EntryPointNotFoundException) { }
        }
    }
}
