// Native macOS icon packaging: preserve the artwork, add a rounded silhouette and transparent outer padding.
const fs=require('fs'),path=require('path');
const sharp=require(process.env.SHARP_MODULE||'sharp');
const root=path.resolve(__dirname,'..');
async function main(){
 const mask=Buffer.from('<svg width="824" height="824"><rect width="824" height="824" rx="184" fill="white"/></svg>');
 const art=await sharp(path.join(root,'assets/logo.png')).resize(824,824).ensureAlpha().composite([{input:mask,blend:'dest-in'}]).png().toBuffer();
 const full=await sharp({create:{width:1024,height:1024,channels:4,background:{r:0,g:0,b:0,alpha:0}}}).composite([{input:art,left:100,top:100}]).png().toBuffer();
 fs.writeFileSync(path.join(root,'assets/macos-icon.png'),full);
 const entries=[['icp4',16],['icp5',32],['icp6',64],['ic07',128],['ic08',256],['ic09',512],['ic10',1024],['ic11',32],['ic12',64],['ic13',256],['ic14',512]],chunks=[];
 for(const [tag,size] of entries){const png=await sharp(full).resize(size,size).png().toBuffer();const header=Buffer.alloc(8);header.write(tag);header.writeUInt32BE(png.length+8,4);chunks.push(header,png);}
 const payload=Buffer.concat(chunks),header=Buffer.alloc(8);header.write('icns');header.writeUInt32BE(payload.length+8,4);
 fs.writeFileSync(path.join(root,'macos/Resources/AppIcon.icns'),Buffer.concat([header,payload]));
 console.log('Rounded macOS icon generated, all sizes 16–1024.');
}
main().catch(e=>{console.error(e);process.exit(1)});
