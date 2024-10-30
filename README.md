## vncimgsrv.lua

A Lua script that serves a static image over VNC made with simplicity and portability in mind

#### Dependencies and requirements
Depends: Lua >= 5.3 and Luasocket

vncimgsrv.lua doesn't require either a graphical environment or elevated privileges. It's also platform-agnostic, meaning it's not limited to only run on Windows/macOS/Linux: as long as it's connected to the net and has a Lua interpreter with the Luasocket module installed, it should work just fine on any device, no matter the OS!

#### Usage
```
lua vncimgsrv.lua [options] file
```
The image must be a 24bpp or 32bpp uncompressed bitmap file.

For a list of supported options, run ```lua vncimgsrv.lua --help```

#### Why?
Aside from being used as a practical joke (like [this](https://fedi.computernewb.com/@vncresolver/113144775166399068) for example), vncimgsrv.lua can be employed similarly to [endlessh](https://github.com/skeeto/endlessh): you can run it on port 5900 and set up your VNC server to use a different one, so script kiddies trying to connect will essentially reach a fake server while leaving alone your real one. For this purpose, the ```--tarpit``` option can prove useful, as it has the potential to lock in connecting clients for a long time by repeatedly sending an image pixel by pixel *very* slowly.

#### Tips
For the best performance possible, it's best to use 32-bit XRGB8888 bitmap files.
