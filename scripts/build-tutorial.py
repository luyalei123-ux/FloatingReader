#!/usr/bin/env python3
"""Render the short tutorial to a standalone, offline HTML document."""
from pathlib import Path
from html import escape
import base64
root=Path(__file__).resolve().parent.parent
lines=(root/'docs/新手使用教程.md').read_text().splitlines()
body=[];table=False;listing=False
for line in lines+['']:
 if line.startswith('|'):
  if not table:body.append('<table>');table=True
  cells=[v.strip() for v in line.strip('|').split('|')]
  if all(set(v)<=set(' :-') for v in cells):continue
  body.append('<tr>'+''.join('<td>'+escape(v)+'</td>' for v in cells)+'</tr>');continue
 if table:body.append('</table>');table=False
 if len(line)>2 and line[0].isdigit() and line[1:3]=='. ':
  if not listing:body.append('<ol>');listing=True
  body.append('<li>'+escape(line[3:])+'</li>');continue
 if listing:body.append('</ol>');listing=False
 if line.startswith('## '):body.append('<h2>'+escape(line[3:])+'</h2>')
 elif line.startswith('# '):body.append('<h1>'+escape(line[2:])+'</h1>')
 elif line:body.append('<p>'+escape(line)+'</p>')
image=root/'assets/reading-preview.png'
if image.exists():body.insert(1,'<img alt="原创示例文字的浮读界面" src="data:image/png;base64,'+base64.b64encode(image.read_bytes()).decode()+'">')
html='<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>浮读新手使用教程</title><style>body{font:16px/1.8 system-ui,sans-serif;color:#333;background:#fbf6ed;margin:0}main{max-width:860px;padding:32px 24px 80px;margin:auto}h1{font-size:30px}h2{font-size:22px;margin-top:36px}img{max-width:100%;border:1px solid #ddd;border-radius:12px}table{border-collapse:collapse;width:100%;background:#fff8}td{border:1px solid #d9d3c8;padding:8px}li{margin-bottom:8px}</style><main>'+''.join(body)+'</main></html>'
(root/'docs/新手使用教程.html').write_text(html)
print('Offline tutorial updated')
