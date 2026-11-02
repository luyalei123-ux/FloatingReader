using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
namespace FloatingReader.Windows;
public sealed class ColorWheel : FrameworkElement {
    double _h,_s,_v=1;
    BitmapSource? _image;
    public event Action<Color>? Changed;
    public double Brightness {get=>_v;set{_v=Math.Clamp(value,0,1);_image=null;InvalidateVisual();}}
    public void SetColor(Color c){double r=c.R/255d,g=c.G/255d,b=c.B/255d,max=Math.Max(r,Math.Max(g,b)),min=Math.Min(r,Math.Min(g,b)),d=max-min;_v=max;_s=max==0?_s:d/max;if(d>0)_h=(max==r?(g-b)/d%6:max==g?(b-r)/d+2:(r-g)/d+4)*60;if(_h<0)_h+=360;_image=null;InvalidateVisual();}
    public Color Current=>Hsv(_h,_s,_v);
    static Color Hsv(double h,double s,double v){double c=v*s,x=c*(1-Math.Abs(h/60%2-1)),m=v-c;var (r,g,b)=h switch{<60=>(c,x,0d),<120=>(x,c,0d),<180=>(0d,c,x),<240=>(0d,x,c),<300=>(x,0d,c),_=>(c,0d,x)};return Color.FromRgb((byte)Math.Round((r+m)*255),(byte)Math.Round((g+m)*255),(byte)Math.Round((b+m)*255));}
    protected override void OnRender(DrawingContext dc){base.OnRender(dc);const int n=256;if(_image is null){var pixels=new byte[n*n*4];for(int y=0;y<n;y++)for(int x=0;x<n;x++){double dx=(x-127.5)/127.5,dy=(y-127.5)/127.5,s=Math.Sqrt(dx*dx+dy*dy);if(s>1)continue;double h=(Math.Atan2(-dy,dx)*180/Math.PI+360)%360;var c=Hsv(h,s,_v);int i=(y*n+x)*4;pixels[i]=c.B;pixels[i+1]=c.G;pixels[i+2]=c.R;pixels[i+3]=255;}_image=BitmapSource.Create(n,n,96,96,PixelFormats.Bgra32,null,pixels,n*4);_image.Freeze();}double size=Math.Min(ActualWidth,ActualHeight);dc.DrawImage(_image,new Rect(0,0,size,size));double angle=_h*Math.PI/180,radius=size*.5;var p=new Point(radius+Math.Cos(angle)*_s*radius,radius-Math.Sin(angle)*_s*radius);dc.DrawEllipse(null,new Pen(Brushes.White,3),p,5,5);dc.DrawEllipse(null,new Pen(Brushes.DimGray,1),p,5,5);}
    void Pick(MouseEventArgs e){var p=e.GetPosition(this);double radius=Math.Min(ActualWidth,ActualHeight)/2,dx=(p.X-radius)/radius,dy=(p.Y-radius)/radius;_h=(Math.Atan2(-dy,dx)*180/Math.PI+360)%360;_s=Math.Clamp(Math.Sqrt(dx*dx+dy*dy),0,1);InvalidateVisual();Changed?.Invoke(Current);}
    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e){base.OnMouseLeftButtonDown(e);CaptureMouse();Pick(e);e.Handled=true;}
    protected override void OnMouseMove(MouseEventArgs e){base.OnMouseMove(e);if(IsMouseCaptured&&e.LeftButton==MouseButtonState.Pressed)Pick(e);}
    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e){base.OnMouseLeftButtonUp(e);ReleaseMouseCapture();}
}
