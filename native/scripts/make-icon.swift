import AppKit
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var chunks = Data()
func sizeBytes(_ size:Int) -> Data { var value = UInt32(size).bigEndian; return withUnsafeBytes(of:&value) { Data($0) } }
for size in [16,32,64,128,256,512,1024] {
    let s = CGFloat(size)
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil, pixelsWide:size, pixelsHigh:size, bitsPerSample:8, samplesPerPixel:4, hasAlpha:true, isPlanar:false, colorSpaceName:.deviceRGB, bytesPerRow:0, bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
    let rect = NSRect(x:s*0.05,y:s*0.05,width:s*0.9,height:s*0.9)
    let bg = NSBezierPath(roundedRect:rect,xRadius:s*0.21,yRadius:s*0.21)
    NSGradient(starting:NSColor(red:0.49,green:0.39,blue:0.94,alpha:1),ending:NSColor(red:0.25,green:0.19,blue:0.66,alpha:1))!.draw(in:bg,angle:-60)
    NSColor.white.withAlphaComponent(0.40).setFill()
    NSBezierPath(roundedRect:NSRect(x:s*0.38,y:s*0.24,width:s*0.4,height:s*0.35),xRadius:s*0.11,yRadius:s*0.11).fill()
    NSColor.white.setFill()
    NSBezierPath(roundedRect:NSRect(x:s*0.20,y:s*0.40,width:s*0.49,height:s*0.37),xRadius:s*0.11,yRadius:s*0.11).fill()
    let tail = NSBezierPath(); tail.move(to:NSPoint(x:s*0.28,y:s*0.45)); tail.line(to:NSPoint(x:s*0.26,y:s*0.32)); tail.line(to:NSPoint(x:s*0.43,y:s*0.43)); tail.close(); tail.fill()
    NSColor(red:0.46,green:0.36,blue:0.86,alpha:1).setFill()
    for x in [0.32,0.44,0.56] { NSBezierPath(ovalIn:NSRect(x:s*x,y:s*0.56,width:s*0.045,height:s*0.045)).fill() }
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using:.png,properties:[:])!
    let names: [String]
    switch size {
    case 16: names=["icon_16x16.png"]
    case 32: names=["icon_16x16@2x.png","icon_32x32.png"]
    case 64: names=["icon_32x32@2x.png"]
    case 128: names=["icon_128x128.png"]
    case 256: names=["icon_128x128@2x.png","icon_256x256.png"]
    case 512: names=["icon_256x256@2x.png","icon_512x512.png"]
    default: names=["icon_512x512@2x.png"]
    }
    for name in names { try data.write(to:output.appendingPathComponent(name)) }
    let types = [16:"icp4",32:"icp5",64:"icp6",128:"ic07",256:"ic08",512:"ic09",1024:"ic10"]
    chunks.append(Data(types[size]!.utf8)); chunks.append(sizeBytes(data.count + 8)); chunks.append(data)
}

var icns = Data("icns".utf8); icns.append(sizeBytes(chunks.count + 8)); icns.append(chunks)
try icns.write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
