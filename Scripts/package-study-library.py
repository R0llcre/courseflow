#!/usr/bin/env python3
"""Create a portable, offline course library. Never modifies source course files."""
from pathlib import Path
from html import escape
from urllib.parse import urlparse,unquote
import base64,hashlib,json,mimetypes,re,shutil,subprocess,zipfile,sys,argparse
sys.path.insert(0,str(Path.home()/"Library/Caches/CourseflowBuildTools"))
from latex2mathml.converter import convert as mathml
import markdown,nbformat
from bs4 import BeautifulSoup
from nbconvert import HTMLExporter
from PIL import Image
from pypdf import PdfReader

ROOT=Path(__file__).resolve().parents[1]
BASE=ROOT.parent.parent
parser=argparse.ArgumentParser()
parser.add_argument('--workspace',action='store_true',help='Build refreshable workspace catalog without changing the installed App')
args=parser.parse_args()
WORKSPACE=ROOT.parent/'课程数据'
OUT=WORKSPACE/'预览缓存' if args.workspace else ROOT/'App/Resources/StudyFiles'
OUT.mkdir(parents=True,exist_ok=True)
seed_path=WORKSPACE/'当前资料与进度.json' if args.workspace else ROOT/'App/Resources/berkeley-fall-2026.json'
if not seed_path.exists():seed_path=ROOT/'App/Resources/berkeley-fall-2026.json'
SEED=json.loads(seed_path.read_text())
FOLDERS={
'dma':'DATA 144 - EDUC 244 - Data Mining and Analytics',
'c200':'DEVENG C200 - Design Evaluate Scale Development Technologies',
'203':'DEVENG 203 - Digital Transformation of Development',
'nlp':'EECS 183-283A - Natural Language Processing',
'ml':'EECS 189-289A - Introduction to Machine Learning',
'shape':'SHAPE 2026-2027 - Student Training',
'mdev':'MDevEng 2027 - Program and Projects'}
GUIDES={
'dma':('从数据预处理到聚类、分类与神经网络。这里汇集课程日程、阅读和 Lab 材料。','周三 14:00–17:00；课程安排记录为 Zoom。'),
'c200':('围绕发展问题开展用户研究、团队项目与设计评估。阅读、课堂材料和小组交付分别整理。','周五 09:00–12:00 · Jacobs Hall 310'),
'203':('编程、数据可视化、传感器、GIS 与遥感在发展实践中的应用。','周一课堂；完整主题表见课程安排。'),
'nlp':('自然语言处理课程。HW1 的说明、notebook、配图与完整原始材料可以直接阅读或导出。','课堂安排以课程公告为准；作业入口为 Gradescope。'),
'ml':('机器学习课程。HW1 的书面题、代码 notebook 和原始材料按 Part 1 / Part 2 整理。','提交平台为 Pensive；课堂安排以课程网站为准。'),
'shape':('学生培训空间。查看培训要求、模块入口和已有核对记录。','培训安排见 Modules；未核实的截止不补造。'),
'mdev':('项目与学务资源。历史项目要求与本学期待办分开查看。','项目公告与活动安排以 bCourses 为准。')}
CSS='''
:root {color-scheme:light dark; font:17px -apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif; line-height:1.75;}
body{margin:0 auto; padding:32px 36px 80px; max-width:850px; color:light-dark(#17212b,#e5eaf1); background:light-dark(#fff,#1b222d)}
h1{font-size:1.9em;line-height:1.35;margin:0 0 1em}h2{font-size:1.4em;margin-top:2em}h3{font-size:1.15em}
p,li{max-width:78ch}a{color:light-dark(#165eb7,#87baff);text-decoration:underline;text-underline-offset:3px}
pre{padding:16px;overflow:auto;background:light-dark(#f2f5f8,#111821);border-radius:8px;white-space:pre-wrap;overflow-wrap:anywhere;font:13px/1.65 ui-monospace,Menlo,monospace}
code{font-family:ui-monospace,Menlo,monospace;overflow-wrap:anywhere}table{border-collapse:collapse;display:block;overflow-x:auto;width:100%;font-size:.92em}th,td{border:1px solid light-dark(#d8e0e8,#425063);padding:9px 12px;text-align:left;vertical-align:top}th{background:light-dark(#eef3f8,#243040)}
img,svg{max-width:100%;height:auto;background:white}a.anchor-link{display:none}blockquote{border-left:3px solid #91a7bf;margin-left:0;padding-left:18px;color:light-dark(#4c5b6a,#bdc8d5)}
math[display=block]{display:block;margin:1.2em auto;overflow-x:auto}details.toc{border:1px solid light-dark(#d8e0e8,#425063);padding:12px 18px;border-radius:8px;margin-bottom:28px}details.toc summary{cursor:pointer;font-weight:600}details.toc nav{max-height:280px;overflow:auto;font-size:.9em}.missing-image{padding:12px;background:#fff1d1;color:#5d4000}.jp-InputPrompt,.jp-OutputPrompt{font-size:11px;color:#728096;min-width:45px}.jp-Cell{margin:26px 0}.jp-InputArea-editor{border:0!important}.jp-OutputArea-output{overflow:auto}.jp-RenderedHTMLCommon{line-height:1.75!important;font-size:inherit!important}script{display:none}
@media(max-width:540px){body{padding:24px 18px}h1{font-size:1.6em}}'''
resources=[]; source_map={};warnings=[]
provenance={};provenance_labels={}
def source_key(url):
 """Identify the same official file across view/download/share URLs."""
 if not url:return None
 parts=urlparse(url)
 if parts.hostname=='bcourses.berkeley.edu':
  match=re.match(r'(/courses/\d+/files/\d+)(?:/|$)',parts.path)
  if match:return 'canvas:'+match[1]
 if parts.hostname in {'docs.google.com','drive.google.com'}:
  match=re.search(r'/(?:document|presentation|file)/d/([^/]+)',parts.path)
  if match:return 'google-file:'+match[1]
 return url
submitted_files={}
for course_folder in FOLDERS.values():
 record=BASE/course_folder/'99_来源与下载记录/提交归档.json'
 if record.exists():
  for item in json.loads(record.read_text()):
   archived=(BASE/course_folder/item['relativePath']).resolve()
   if archived.is_relative_to((BASE/course_folder).resolve()) and archived.is_file() and hashlib.sha256(archived.read_bytes()).hexdigest()==item['sha256']:
    submitted_files[str(archived)]=item
 for record in sorted((BASE/course_folder/'99_来源与下载记录').glob('*下载*.json')):
  records=json.loads(record.read_text())
  if isinstance(records,dict):records=[records]
  for item in records:
   if 'file' not in item or 'source' not in item:continue
   original=Path(item['file']).resolve()
   if not original.is_relative_to((BASE/course_folder).resolve()) or not original.is_file():continue
   if item.get('sha256') and hashlib.sha256(original.read_bytes()).hexdigest()!=item['sha256']:continue
   key=str(original);provenance[key]=item['source']
   provenance_labels[key]=item.get('sourceLabel','官方课程材料 · 已保存原文件')

def ident(value): return 'study-'+hashlib.sha256(value.encode()).hexdigest()[:16]
def category(path):
 parts=str(path)
 if '90_我的提交' in parts or '05_作业成果' in parts or '08_作业草稿' in parts or parts.startswith('output/') or '构思' in parts: return 'work'
 if '02_课件' in parts:return 'lecture'
 if '03_阅读' in parts:return 'reading'
 if '04_作业' in parts or '05_测验' in parts:return 'assignment'
 if '06_公告' in parts or '99_来源' in parts or '状态' in parts:return 'announcement'
 return 'overview'

def tasks(cid,path):
 s=str(path).lower(); found=[]
 # Versioned requirement notes carry the stable assignment ID in their filename.
 exact=[t['id'] for t in SEED['assignments'] if t['courseID']==cid and Path(str(path)).name.startswith(t['id']+'_')]
 if exact:return exact
 if cid=='dma' and re.search(r'lab[ _-]*1(?:\b|_)',s):found=['dma-lab-1']
 elif cid=='dma' and re.search(r'lab[ _-]*2(?:\b|_)',s):found=['dma-lab-2']
 elif cid=='dma' and re.search(r'lab[ _-]*3(?:\b|_)',s):found=['dma-lab-3']
 elif cid=='nlp' and ('hw1' in s or 'assignment 1' in s):found=['nlp-hw-1']
 elif cid=='nlp' and ('hw2' in s or 'assignment 2' in s):found=['nlp-hw-2']
 elif cid=='ml':
  if 'hw1-pt1' in s or 'startup_pt1' in s:found=['ml-hw-1-part-1']
  elif 'hw1-pt2' in s or 'startup_pt2' in s:found=['ml-hw-1-part-2']
  elif 'hw1' in s:found=['ml-hw-1-part-1','ml-hw-1-part-2']
 elif cid=='203':
  normalized=re.sub(r'[ _-]+','',s)
  if 'introsurvey' in normalized:found=['203-intro-survey']
  elif any(x in normalized for x in ['week3chi','week3lynch','week3park']):found=['203-discussion-3']
  elif 'week3' in normalized:found=['203-week-3']
  elif 'week2discussion' in normalized or any(x in normalized for x in ['week2crameri','week2datafeminism','week2tufte']):found=['203-discussion-2']
  elif 'week2' in normalized:found=['203-week-2']
  elif 'week1' in normalized:found=['203-week-1']
  elif 'presentation' in normalized:found=['203-presentation']
 elif cid=='c200' and 'introduction_to_development_engineering_2023.pdf' in s:found=['c200-reading-1','c200-reading-2','c200-reading-week-5']
 elif cid=='c200':
  for token,task in [('reading_response_1','c200-reading-1'),('reading_response_2','c200-reading-2'),('week_3','c200-reading-week-3'),('team_project','c200-project-preference'),('mou','c200-mou'),('签到','c200-attendance-1'),('签到','c200-attendance-2')]:
   if token in s:found.append(task)
 if cid=='shape' and '培训' in s:found=['shape-training']
 valid={t['id'] for t in SEED['assignments']}
 return [t for t in dict.fromkeys(found) if t in valid]

def title(path,source):
 if path.name == 'README.md' and path.parent.name in FOLDERS.values(): return '课程入口与说明'
 if path.name == 'f1.png': return 'HW1 · F1 评分公式配图'
 if path.suffix=='.md':
  heading=re.search(r'^#\s+(.+)',source,re.M)
  if heading:return heading[1]
 return path.stem.replace('_',' ')

def doc_html(content,title):
 return f'<!doctype html><html lang="zh"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="Content-Security-Policy" content="default-src \'none\'; img-src data: file:; style-src \'unsafe-inline\'; font-src data:; base-uri \'none\'"><title>{escape(title)}</title><style>{CSS}</style></head><body>{content}</body></html>'

# First establish all stable file IDs, then rewrite cross-document links.
files=[]
allowed={'.md','.pdf','.png','.jpg','.jpeg','.ipynb','.docx','.pptx','.csv'}
for cid,folder in FOLDERS.items():
 for path in sorted((BASE/folder).rglob('*')):
  if not path.is_file() or path.is_symlink() or not path.resolve().is_relative_to((BASE/folder).resolve()) or path.name.startswith('~$') or path.name == '当前状态_课序生成.md' or any(p.startswith('.') or p.startswith('旧版_') or p.startswith('历史版本') or p in {'tmp','node_modules','vendor','build','__pycache__'} for p in path.relative_to(BASE/folder).parts):continue
  rid=ident(cid+'/'+str(path.relative_to(BASE/folder)))
  source_map[str(path.resolve())]=rid
  files.append((cid,path,rid))

def clean_html(raw,path):
 soup=BeautifulSoup(raw,'html.parser')
 for script in soup.find_all(['script','iframe','object','embed']):script.decompose()
 for el in soup.find_all(True):
  for key in list(el.attrs):
   if key.startswith('on'):del el[key]
 for img in soup.find_all('img'):
  src=img.get('src','')
  if src == 'https://colab.research.google.com/assets/colab-badge.svg':
   img.replace_with(soup.new_string('在 Colab 打开')); continue
  if src.startswith('data:image/'):continue
  local=(path.parent/unquote(src)).resolve()
  if not urlparse(src).scheme and local.is_file() and local.is_relative_to(BASE):
   mime=mimetypes.guess_type(str(local))[0] or 'image/png'
   img['src']='data:'+mime+';base64,'+base64.b64encode(local.read_bytes()).decode()
  else:
   tag=soup.new_tag('p',attrs={'class':'missing-image'})
   tag.string='原文图片未保存到本机：'+(img.get('alt') or src)
   img.replace_with(tag); warnings.append({'file':str(path.relative_to(BASE)),'missingImage':src})
 for a in soup.find_all('a',href=True):
  href=a['href']
  if href.startswith('#'):continue
  if href.startswith('https://'):continue
  target=(path.parent/unquote(href.split('#')[0])).resolve()
  if str(target) in source_map: a['href']='courseflow-resource://'+source_map[str(target)]
  else: a.unwrap()
 headings=soup.find_all(['h1','h2','h3'])
 if len(headings)>3:
  toc=soup.new_tag('details',attrs={'class':'toc'})
  summary=soup.new_tag('summary');summary.string=f'目录 · {len(headings)} 个章节';toc.append(summary)
  nav=soup.new_tag('nav');listing=soup.new_tag('ul')
  for i,heading in enumerate(headings):
   if not heading.get('id'):heading['id']='section-'+str(i)
   li=soup.new_tag('li');a=soup.new_tag('a',href='#'+heading['id']);a.string=heading.get_text(' ',strip=True).replace('¶','');li.append(a);listing.append(li)
  nav.append(listing);toc.append(nav);soup.insert(0,toc)
 return str(soup)

MATH_PATTERN=re.compile(r'(```[\s\S]*?```|`[^`]*`)|(\$\$[\s\S]*?\$\$|(?<!\\)\$[^$\n]+(?<!\\)\$)')
def protect_math(source, replacements):
 def replace(match):
  if match.group(1):return match.group(0)
  value=match.group(2);block=value.startswith('$$');latex=value[2:-2] if block else value[1:-1]
  try:
   token=f'COURSEFLOWMATHTOKEN{len(replacements):04d}'
   replacements[token]=mathml(latex,display='block' if block else 'inline')
   return token
  except Exception as e:
   warnings.append({'math':latex,'error':str(e)});return value
 return MATH_PATTERN.sub(replace,source)

for cid,path,rid in files:
 ext=path.suffix.lower(); preview=None;thumb=None;content='';original=rid+ext
 if not args.workspace: shutil.copy2(path,OUT/original)
 if ext in {'.md','.ipynb'}:
  if ext=='.md':
   source=path.read_text(); content=source
   body=markdown.markdown(source,extensions=['tables','fenced_code','sane_lists'])
  else:
   notebook=nbformat.read(path,as_version=4)
   # Rendering is read-only: never execute imported course notebooks.
   content='\n'.join(c.source for c in notebook.cells)
   replacements={}
   for cell in notebook.cells:
    if cell.cell_type=='markdown':cell.source=protect_math(cell.source,replacements)
   rendered,_=HTMLExporter(template_name='basic').from_notebook_node(notebook)
   parsed=BeautifulSoup(rendered,'html.parser')
   # nbconvert also puts heading text into IDs. MathML must replace text only,
   # never attribute values; keep heading IDs and their anchors valid strings.
   for element in parsed.find_all(True):
    for key,value in list(element.attrs.items()):
     if isinstance(value,str):element[key]=re.sub(r'COURSEFLOWMATHTOKEN(\d+)',r'math-\1',value)
   token_pattern=re.compile(r'COURSEFLOWMATHTOKEN\d+')
   for node in list(parsed.find_all(string=token_pattern)):
    fragments=[];offset=0
    for match in token_pattern.finditer(str(node)):
     fragments.append(escape(str(node)[offset:match.start()]))
     fragments.append(replacements[match.group(0)])
     offset=match.end()
    fragments.append(escape(str(node)[offset:]))
    replacement=BeautifulSoup(''.join(fragments),'html.parser')
    node.replace_with(*list(replacement.contents))
   body=str(parsed)
  preview=rid+'-read.html'
  (OUT/preview).write_text(doc_html(clean_html(body,path),title(path,content)))
 elif ext in {'.py','.txt','.tsv','.csv','.json','.geojson','.ini','.pgw','.webloc'} and path.stat().st_size <= 1_000_000:
  try:
   content=path.read_text(encoding='utf-8')
   preview=rid+'-read.html'
   (OUT/preview).write_text(doc_html('<pre>'+escape(content)+'</pre>',title(path,content)))
  except (UnicodeError,OSError):pass
 elif ext=='.pdf':
  try:
   reader=PdfReader(path)
   content='\n'.join(p.extract_text() or '' for p in reader.pages)
   preview=original;thumb=rid+'-thumb.png'
   subprocess.run(['pdftoppm','-f','1','-l','1','-singlefile','-scale-to','360','-png',str(path),str(OUT/(rid+'-thumb'))],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
  except Exception as e:warnings.append({'file':str(path),'error':str(e)});thumb=None
 elif ext in {'.png','.jpg','.jpeg'}:
  preview=original;thumb=rid+'-thumb.png'
  try:
   with Image.open(path) as im:
    im.thumbnail((360,360))
    canvas=Image.new('RGBA',im.size,'white');canvas.alpha_composite(im.convert('RGBA'));canvas.convert('RGB').save(OUT/thumb)
  except (OSError,ValueError) as e:
   # Keep the original indexed even when an image cannot produce a preview.
   warnings.append({'file':str(path),'error':str(e)});preview=None;thumb=None
 fmt={'.md':'markdown','.ipynb':'notebook','.png':'image','.jpg':'image','.jpeg':'image'}.get(ext,ext.lstrip('.'))
 resources.append(dict(id=rid,courseID=cid,title=title(path,content),category=category(path.relative_to(BASE/FOLDERS[cid])),format=fmt,originalName=path.name,originalFile=original,previewFile=preview,thumbnailFile=thumb,sourceURL=provenance.get(str(path.resolve())),sourceLabel=provenance_labels.get(str(path.resolve()),'已保存 notebook · 只读预览' if ext=='.ipynb' else '本地课程文件'),text=BeautifulSoup(content,'html.parser').get_text() if ext=='.md' else content,taskIDs=tasks(cid,path),size=path.stat().st_size))
 resources[-1].update(relativePath=str(path.relative_to(BASE)),modifiedAt=path.stat().st_mtime)
 if str(path.resolve()) in submitted_files:
  resources[-1].update(fileRole='submitted',sourceURL=submitted_files[str(path.resolve())]['sourceURL'],sourceLabel='平台提交文件 · 摘要已核对')

# Add downloadable source archives for coding assignments, excluding repository metadata.
for cid,foldername in [('nlp','2026-09-14_HW1_原始材料_2026-09-07'),('ml','HW1_原始材料_2026-09-07')]:
 source=BASE/FOLDERS[cid]/'04_作业要求'/foldername
 rid=ident(cid+'/hw1-source-archive');filename=rid+'.zip'
 with zipfile.ZipFile(OUT/filename,'w',zipfile.ZIP_DEFLATED) as z:
  for path in sorted(source.rglob('*')):
   if path.is_file() and not any(p.startswith('.') for p in path.relative_to(source).parts): z.write(path,str(Path(foldername)/path.relative_to(source)))
 resources.append(dict(id=rid,courseID=cid,title='HW1 完整原始材料包',category='assignment',format='zip',originalName=foldername+'.zip',originalFile=filename,previewFile=None,thumbnailFile=None,sourceURL=None,sourceLabel='本地原始材料，含代码和数据',text='HW1 源文件 notebook 依赖 数据 ZIP',taskIDs=['nlp-hw-1'] if cid=='nlp' else ['ml-hw-1-part-1','ml-hw-1-part-2'],size=(OUT/filename).stat().st_size))

# Use explicit assignment-document links to connect required local readings.
# This does not infer requirements from other documents in the same course.
for cid,path,rid in files:
 task_ids=tasks(cid,path)
 if path.suffix!='.md' or category(path.relative_to(BASE/FOLDERS[cid]))!='assignment' or not task_ids:continue
 soup=BeautifulSoup(markdown.markdown(path.read_text(),extensions=['tables']),'html.parser')
 for a in soup.find_all('a',href=True):
  href=a['href']
  if urlparse(href).scheme:continue
  target=source_map.get(str((path.parent/unquote(href.split('#')[0])).resolve()))
  for resource in resources:
   if resource['id']==target and resource['category'] in ['reading','lecture']:
    resource['taskIDs']=list(dict.fromkeys(resource['taskIDs']+task_ids))

# Online links stay in their subject category, with offline availability per file.
seen={(r['courseID'],source_key(r['sourceURL'])) for r in resources if r['sourceURL']}
for cid,path,rid in files:
 if path.suffix!='.md' or not (any(k in path.name for k in ['索引','README','课程信息']) or (category(path.relative_to(BASE/FOLDERS[cid]))=='assignment' and tasks(cid,path))):continue
 soup=BeautifulSoup(markdown.markdown(path.read_text(),extensions=['tables']),'html.parser')
 for a in soup.find_all('a',href=True):
  url=a['href'];parts=urlparse(url)
  if parts.scheme!='https' or parts.username or parts.password:continue
  task_ids=tasks(cid,path)
  if (cid,source_key(url)) in seen:
   for resource in resources:
    if resource['courseID']==cid and source_key(resource['sourceURL'])==source_key(url):
     resource['taskIDs']=list(dict.fromkeys(resource['taskIDs']+task_ids))
   continue
  seen.add((cid,source_key(url)))
  line=(a.find_parent('tr') or a.parent).get_text(' ',strip=True)
  label=a.get_text(' ',strip=True)
  if label.startswith('https://'):
   label=line.replace(label,'').strip(' :：|<>-')
  if not label:label=parts.netloc
  label=label[:140]
  kind=(label+' '+url).lower()
  if 'syllabus' in kind:cat='overview'
  elif any(k in kind for k in ['slides','lecture','presentation/d/','讲义','tutorial']):cat='lecture'
  elif any(k in kind for k in ['chapter','教材','视频','video','reading','crameri','feminism','tufte','springer']):cat='reading'
  elif any(k in kind for k in ['workshop','lab 1','lab1','homework']):cat='assignment'
  else:cat=category(path)
  lid=ident(cid+'/link/'+url)
  resources.append(dict(id=lid,courseID=cid,title=label,category=cat,format='link',originalName=None,originalFile=None,previewFile=None,thumbnailFile=None,sourceURL=url,sourceLabel='在线原文 · 可能需要课程账号',text=line,taskIDs=list(dict.fromkeys(tasks(cid,label)+task_ids)),size=0))

guides=[]
for cid in FOLDERS:
 local=[r for r in resources if r['courseID']==cid and r['originalFile']]
 online=[r for r in resources if r['courseID']==cid and not r['originalFile']]
 featured=[r['id'] for r in local if r['category'] in ['overview','lecture'] and r['format'] != 'docx'][:4]
 guides.append(dict(id=cid,folder=FOLDERS[cid],summary=GUIDES[cid][0],schedule=GUIDES[cid][1],coverage=f'已收录 {len(local)} 份本地资料，另有 {len(online)} 个在线入口。在线入口不代表已下载；课程状态以原始核对时间为准。',featuredIDs=featured))
catalog=dict(version=1,generatedAt=__import__('datetime').datetime.now(__import__('datetime').timezone.utc).isoformat(),courses=guides,resources=resources)
(WORKSPACE/'course-library.json' if args.workspace else ROOT/'App/Resources/course-library.json').write_text(json.dumps(catalog,ensure_ascii=False,indent=2))
# Remove only obsolete files in this script's managed output directory.
referenced={r[key] for r in resources for key in ['originalFile','previewFile','thumbnailFile'] if r[key]}
for generated in OUT.glob('study-*'):
 if generated.is_file() and generated.name not in referenced:
  generated.unlink()

(WORKSPACE/'资料索引检查.json' if args.workspace else ROOT/'Docs/PACKAGING-REPORT.json').write_text(json.dumps(dict(local=sum(r['originalFile'] is not None for r in resources),online=sum(r['originalFile'] is None for r in resources),courses=guides,warnings=warnings),ensure_ascii=False,indent=2))
print(f'Packaged {len(resources)} resources; {len(warnings)} preview warnings.')
