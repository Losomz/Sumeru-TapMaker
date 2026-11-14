-- SHA-1（纯 Lua 5.4 整数位运算）：TapTap 礼包无服务器兑换的请求签名用。输出 40 位小写十六进制。
local Sha1={}

local M=0xffffffff
local function rol(x,n) return ((x<<n)|(x>>(32-n)))&M end
local function word(s,i)
 local a,b,c,d=s:byte(i,i+3)
 return (a<<24)|(b<<16)|(c<<8)|d
end

function Sha1.hex(msg)
 msg=tostring(msg)
 local bits=#msg*8
 -- 补位：0x80，再补 0 到长度 ≡ 56 (mod 64)，最后 8 字节大端写原文位数
 local tail={}
 for i=7,0,-1 do tail[#tail+1]=string.char((bits>>(i*8))&0xff) end
 msg=msg.."\128"..string.rep("\0",(55-#msg)%64)..table.concat(tail)
 local h0,h1,h2,h3,h4=0x67452301,0xEFCDAB89,0x98BADCFE,0x10325476,0xC3D2E1F0
 local w={}
 for chunk=1,#msg,64 do
  for i=0,15 do w[i]=word(msg,chunk+i*4) end
  for i=16,79 do w[i]=rol(w[i-3]~w[i-8]~w[i-14]~w[i-16],1) end
  local a,b,c,d,e=h0,h1,h2,h3,h4
  for i=0,79 do
   local f,k
   if i<20 then f=(b&c)|((~b)&d);k=0x5A827999
   elseif i<40 then f=b~c~d;k=0x6ED9EBA1
   elseif i<60 then f=(b&c)|(b&d)|(c&d);k=0x8F1BBCDC
   else f=b~c~d;k=0xCA62C1D6 end
   local t=(rol(a,5)+(f&M)+e+k+w[i])&M
   e=d;d=c;c=rol(b,30);b=a;a=t
  end
  h0=(h0+a)&M;h1=(h1+b)&M;h2=(h2+c)&M;h3=(h3+d)&M;h4=(h4+e)&M
 end
 return string.format("%08x%08x%08x%08x%08x",h0,h1,h2,h3,h4)
end

return Sha1
