local socket = require("socket")

function loadbmp(fname)	--remember: bitmap files are always little endian
	local parsed = {imgwidth = 0, imgheight = 0, data = "", bpp}
	local file = assert(io.open(fname, "r"),"could not open "..fname.."! (non-existent file/permissions issue?)")
	local stack = {}
	local diff = 0
	local direction = 1
	local padding = 0
	local pixelpos, headersize, bpp, compression, size, bytesperpixel, rowsize
	
	if file:read(2)~="BM" then 
		error(fname.." does not appear to be a valid bitmap image file!")
	end
	file:seek("set", 10)
	pixelpos = assert(string.unpack("<I4",file:read(4)), "could not read pixel offset from bmp header!")
	file:seek("set", 14)
	headersize = assert(string.unpack("<I4",file:read(4)), "could not read header size from bmp header!")
	if headersize<40 or headersize==64 then --os/2 DIBs use a slightly different DIB header
		error("OS/2 BMP files are currently unsupported") 
	end
	parsed.imgwidth = string.unpack("<i4",file:read(4))
	parsed.imgheight = string.unpack("<i4",file:read(4))
	if parsed.imgwidth>65535 or parsed.imgheight>65535 or parsed.imgheight<-65535 then
		error("image is too big! ("..parsed.imgwidth.."x"..parsed.imgheight..", max size: 65535x65535")
	end
	if parsed.imgwidth==0 or parsed.imgheight==0 then
		error("image has an invalid size!")
	end
	if parsed.imgheight<0 then direction = -1 end
	file:seek("set", 28)
	parsed.bpp = assert(string.unpack("<I2",file:read(2)), "could not read image color depth from dib header! (malformed image?)")
	compression = assert(string.unpack("<I4",file:read(4)), "could not read image compression type from dib header! (malformed image?)")
	if parsed.bpp~=32 and parsed.bpp~=24 then
		error(fname.." is not a 24bpp or 32bpp bitmap image!")
	end
	if compression~=3 and compression~=0 then --BITMAPV3INFOHEADER and later sets the compression field to 3 for 32bpp RGBA
		error(fname.." is not an uncompressed bitmap image!")
	end
	bytesperpixel=parsed.bpp/8
	rowsize=(bytesperpixel)*parsed.imgwidth
	if math.fmod(rowsize,4)~=0 then padding=(((rowsize+4-1)/4)*4)-rowsize end
	size = (rowsize+padding)*math.abs(parsed.imgheight) --BITMAPINFOHEADER's size value is optional for 24bpp uncompressed images and, as such, can be unreliable

	--[[ if the bitmap file is 24bpp, we have to convert it to 32bpp before we can
	use it (see rfb comment below). in our case, we can do so efficiently by using
	a neat 	trick: both the bitmap and rfb pixel array store data in little endian
	(again,see below), so we can effectively convert 24bpp RGB888(BGR888) to 32bpp
	RGBX888(BGRX8888) by overreading one extra byte for each pixel from our source
	mage, as the last byte in BGRX8888 is meaningless and can, therefore, be just
	garbage data 	(of course, we have to be careful if we reach eof!) --]]
	for i = math.abs(math.min(parsed.imgheight,1)), math.max(parsed.imgheight,1), direction do
		file:seek("set",pixelpos+size+((bytesperpixel*parsed.imgwidth*i)*-1)-(padding*i)-diff)
		if diff~=0 then file:seek("cur",1) end --fixes an off-by-one in case we couldn't overread due to reaching eof
		for j = 1, parsed.imgwidth do
			if parsed.bpp==32 then --if the image is 32bpp already we can just read it row-by-row instead of pixel-by-pixel: much faster!
				table.insert(stack,file:read(4*parsed.imgwidth))
				break
			else table.insert(stack,file:read(4+diff)) end
			if j==1 and diff~=0 then file:seek("cur",-1) end --compensates for the off-by-one fix above
			file:seek("cur", -1)
			if string.len(stack[#stack])<4 then --if we can't overread (e.g. eof reached) we will compensate for it during our next read
				diff=4-string.len(stack[#stack])
			else 
				diff=0 
			end
		end
	end
	file:close()
	parsed.data = table.concat(stack,"")

	return parsed
end

function print_logstr(str, client)
	local ip
	if client~=nil then ip=client:getpeername()..", " end

	print("["..os.date("%H:%M").."] - "..(ip or "")..str)
end

function checkarg(i)
	if arg[i+1]==nil then error(arg[i].." requires an argument!") end
end

--[[ why this specific pixel_format configuration? on one hand, the rfb protocol
*only* supports 32, 16 or 8 bpp - if you have a 24bpp image, for example, you
must first convert it to 32bpp and then set the depth to 24 (which tells the
client only 24 out of the 32 bits are meaningful) on the other, while rfb doesn't
discriminate against endianess, some clients (for example tigervnc and its
derivates) have specific code to handle little-endian (X)RGB(8)888 and don't
play well with other formats --]]
local rfb = { ver="RFB 003.008\n", bpp=string.pack("B",32), depth=string.pack("B",24),
bigendian=string.pack("B",0), truecolor=string.pack("B",1), rmax=string.pack(">I2",255),
gmax=string.pack(">I2",255), bmax=string.pack(">I2",255), rshift=string.pack("B",16),
gshift=string.pack("B",8), bshift=string.pack("B",0) }
local rfbrect = {rnum = string.pack(">I4",1), x=string.pack(">I2",0),
y=string.pack(">I2",0), enc=string.pack(">I4",0)}
local ip = "0.0.0.0"
local port = 5900
local server, imgfname, tarpitdelay

argswitch = {	--thank you lua for not having a proper case switch >:(
	["--help"] = function()
		print([[usage: vncimgsrv.lua [options] file
		
file must be a 32bpp uncompressed bmp image
 
 -h, --help		displays this help then exits
 -i, --ip ADDR		bind server to the given address or hostname
 -n, --name NAME	sets server name to NAME
 -p, --port PORT	sets the port to listen on
 -r, --rfbver VERSION	sets the reported rfb protocol version
 			NOTE: even if VERSION can be any value between 0.0 and
 			999.999, the only versions currently published as part
 			of the rfb spec are 3.3, 3.7 and 3.8
 -t, --tarpit SECONDS   enables tarpit mode: instead of transmitting the whole
 			image in one go, it is sent to the client pixel by 
 			pixel repeatedly, sleeping for SECONDS between each
 			one (SECONDS<=0 disables sleeping)
 			this can be useful to slow down bad actors trying
 			to connect via port scrapers as much as possible]])
		os.exit()
	end,
	["--ip"] = function(i)
		checkarg(i)
		ip=arg[i+1]
	end,
	["--name"] = function(i)
		checkarg(i)
		rfb.name=assert(arg[i+1],"invalid name given!")
	end,
	["--port"] = function(i)
		checkarg(i)
		port=tonumber(arg[i+1])
		if port==nil or port>65535 or port<=0 or math.fmod(port,1)~=0 then
			error("invalid port!")
		end
	end,
	["--rfbver"] = function(i)
		local rfbarg=tonumber(arg[i+1])
		checkarg(i)
		if rfbarg==nil or rfbarg>999.999 or rfbarg<=0 then
			error("invalid rfb protocol version!")
		end
		rfb.ver=string.format("RFB %07.3f\n", arg[i+1])
	end,
	["--tarpit"] = function(i)
		checkarg(i)
		tarpitdelay=assert(tonumber(arg[i+1]), "incorrect tarpit delay number!")
	end,
}

argswitch["-h"] = argswitch["--help"]
argswitch["-t"] = argswitch["--tarpit"]
argswitch["-r"] = argswitch["--rfbver"]
argswitch["-i"] = argswitch["--ip"]
argswitch["-p"] = argswitch["--port"]
argswitch["-n"] = argswitch["--name"]

for i,v in ipairs(arg) do
	if argswitch[arg[i]] then 
		argswitch[arg[i]](i)
		i = i + 1
	else
		if string.sub(arg[i],1,1)=="-" then
			error("unknown argument "..arg[i])
		else
			if i-1==0 or string.sub(arg[i-1],1,1)~="-" then 
				if imgfname==nil then
					imgfname=arg[i]
				else
					error("unexpected argument "..arg[i])
				end
			end
		end
	end
end

if imgfname==nil then error("no file name was provided!") end
server = assert(socket.bind(ip, port))
print("vncimgsrv.lua - listening on "..ip..":" ..port)
bmp = loadbmp(imgfname, "r")
print_logstr("bitmap loaded ("..bmp.bpp.."bpp)")
rfb.w=string.pack(">I2",bmp.imgwidth)
rfb.h=string.pack(">I2",math.abs(bmp.imgheight))
if rfb.name==nil then rfb.name=imgfname end
rfb.namelen=string.pack(">I4",string.len(rfb.name))
rfb.name=string.pack(">c"..string.len(rfb.name),rfb.name)
print_logstr("ready")
while 1 do
    local client = server:accept()
    client:settimeout(9)
    print_logstr("client connected", client)
    client:send(rfb.ver)
    local msg, err = client:receive()
    while not err and "quit" ~= msg do
    	if msg:sub(1,4)=="RFB " then 
    		print_logstr("client requested to use "..msg, client)
    		if msg=="RFB 003.003" then
    			client:send(string.pack(">I4",1))
    		else
    			client:send(string.pack("B",1)..string.pack("B",1)) --see rfb 3.7+ security type list format
    			if msg=="RFB 003.008" then client:send(string.pack(">I4",0)) end
    		end
    		print_logstr("sending serverinit", client)
		client:send(rfb.w..rfb.h..rfb.bpp..rfb.depth..rfb.bigendian..rfb.truecolor..
		rfb.rmax..rfb.gmax..rfb.bmax..rfb.rshift..rfb.gshift..rfb.bshift..
		string.pack(">I3",0)..rfb.namelen..rfb.name)
		print_logstr("sending framebufferupdate", client)
		if tarpitdelay~=nil then
			while client:getpeername()~=nil do
				local j = 0
				local k = 0
				for i = 0, (string.len(bmp.data)/4)-1 do
					client:send(rfbrect.rnum..string.pack(">I2",j)..string.pack(">I2",k)..
					string.pack(">I2",1)..string.pack(">I2",1)..rfbrect.enc..
					string.sub(bmp.data,(i*4)+1,(i*4)+4)) --BGRX8888 (little endian XRGB8888)
					if j==bmp.imgwidth-1 then 
						j = 0
						k = k + 1
					else 
						j = j + 1
					end
					if client:getpeername()==nil then 
						client:close()
						break
					end
					socket.sleep(tarpitdelay)
				end
			end
		else
			client:send(rfbrect.rnum..rfbrect.x..rfbrect.y..rfb.w..rfb.h..
			rfbrect.enc..bmp.data) --BGRX8888 (little endian XRGB8888)
			while client:getpeername()~=nil do
				client:send(string.pack(">I4",0)) --send an empty framebufferupdate as a ping
				socket.sleep(0.5)
				if client:getpeername()==nil then
					client:close()
					break
				end
			end
		end
	end
        print_logstr("client disconnected")
        msg, err = client:receive()
    end
end
