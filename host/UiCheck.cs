using System; using System.Drawing; using System.Windows.Forms; using System.Reflection; using System.IO;
class Check {
[STAThread] static void Main() {
Application.EnableVisualStyles();
var a=Assembly.LoadFrom("MediaControl.exe"); var t=a.GetType("MediaTerminalControl.BoardLink");
ushort crc=(ushort)t.GetMethod("Crc").Invoke(null,new object[]{System.Text.Encoding.ASCII.GetBytes("123456789"),0,9});
string frame=BitConverter.ToString((byte[])t.GetMethod("Frame").Invoke(null,new object[]{(byte)0x11,(byte)7,(ushort)0,(ushort)0x10}));
if(crc!=0x29b1 || frame!="A5-5A-11-07-00-00-10-00-93-35") throw new Exception("protocol");
File.WriteAllText("verification/protocol.txt","CRC=29B1; Frame="+frame+"; PASS");
foreach(string mode in new[]{"default","small","large-font"}) {
using(var f=(Form)Activator.CreateInstance(a.GetType("MediaTerminalControl.MainWindow"),true)) {
f.Show(); Application.DoEvents();
if(mode=="small") f.Size=new Size(700,560);
if(mode=="large-font") {f.Font=new Font("Microsoft YaHei UI",15); f.Scale(new SizeF(1.5f,1.5f)); f.Size=new Size(1280,1000);}
Application.DoEvents(); f.PerformLayout(); Application.DoEvents();
using(var b=new Bitmap(f.Width,f.Height)) {f.DrawToBitmap(b,new Rectangle(Point.Empty,f.Size)); b.Save("verification/"+mode+".png");}
foreach(Control c in f.Controls) { Panel panel=c as Panel; if(panel!=null) panel.AutoScrollPosition=new Point(0,2000); } Application.DoEvents(); using(var bottom=new Bitmap(f.Width,f.Height)) {f.DrawToBitmap(bottom,new Rectangle(Point.Empty,f.Size)); bottom.Save("verification/"+mode+"-bottom.png");} f.Close();
}
}
}
}