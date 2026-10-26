import AppKit
let destination=CommandLine.arguments[1]
let image=NSImage(size:NSSize(width:1024,height:1024))
image.lockFocus()
let rect=NSRect(x:64,y:64,width:896,height:896)
let outline=NSBezierPath(roundedRect:rect,xRadius:210,yRadius:210)
NSGradient(starting:NSColor(calibratedRed:0.30,green:0.47,blue:1,alpha:1),ending:NSColor(calibratedRed:0.14,green:0.23,blue:0.69,alpha:1))!.draw(in:outline,angle:-65)
let gate=NSBezierPath();gate.lineWidth=58;gate.lineCapStyle = .round;gate.lineJoinStyle = .round
gate.move(to:NSPoint(x:345,y:328));gate.line(to:NSPoint(x:345,y:628));gate.curve(to:NSPoint(x:679,y:628),controlPoint1:NSPoint(x:345,y:846),controlPoint2:NSPoint(x:679,y:846));gate.line(to:NSPoint(x:679,y:328))
NSColor.white.setStroke();gate.stroke()
let link=NSBezierPath();link.lineWidth=48;link.lineCapStyle = .round;link.move(to:NSPoint(x:461,y:461));link.line(to:NSPoint(x:563,y:461));NSColor.white.withAlphaComponent(0.95).setStroke();link.stroke()
for x in [345.0,679.0]{let dot=NSBezierPath(ovalIn:NSRect(x:x-44,y:266,width:88,height:88));NSColor(calibratedRed:0.46,green:0.98,blue:0.80,alpha:1).setFill();dot.fill()}
image.unlockFocus()
let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:destination))
