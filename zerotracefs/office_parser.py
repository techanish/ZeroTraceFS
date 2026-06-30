import zipfile
import io
import xml.etree.ElementTree as ET
import base64
import re

def parse_docx_to_html(content_bytes: bytes) -> str:
    html = ["<div style='font-family: \"Segoe UI\", Arial, sans-serif; padding: 20px; line-height: 1.6;'>"]
    try:
        with zipfile.ZipFile(io.BytesIO(content_bytes)) as z:
            rels = {}
            try:
                rels_xml = z.read("word/_rels/document.xml.rels")
                rels_tree = ET.XML(rels_xml)
                for rel in rels_tree:
                    rId = rel.attrib.get('Id')
                    target = rel.attrib.get('Target')
                    if rId and target:
                        rels[rId] = target
            except Exception:
                pass

            document_xml = z.read("word/document.xml")
            tree = ET.XML(document_xml)
            for p in tree.iter("{http://schemas.openxmlformats.org/wordprocessingml/2006/main}p"):
                p_html = []
                for node in p.iter():
                    if node.tag == "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}t":
                        if node.text:
                            p_html.append(node.text)
                    elif node.tag == "{http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing}inline":
                        for blip in node.iter("{http://schemas.openxmlformats.org/drawingml/2006/main}blip"):
                            embed_id = blip.attrib.get("{http://schemas.openxmlformats.org/officeDocument/2006/relationships}embed")
                            if embed_id and embed_id in rels:
                                target = rels[embed_id]
                                img_path = f"word/{target}"
                                try:
                                    img_data = z.read(img_path)
                                    b64 = base64.b64encode(img_data).decode('utf-8')
                                    ext = target.split('.')[-1].lower()
                                    mime = f"image/{ext}" if ext in ['png', 'jpeg', 'gif'] else "image/jpeg"
                                    p_html.append(f"<br><img src='data:{mime};base64,{b64}' style='max-width:100%; border-radius: 8px; margin: 10px 0;'><br>")
                                except Exception:
                                    pass
                if p_html:
                    html.append(f"<p>{''.join(p_html)}</p>")
    except Exception as e:
        html.append(f"<p style='color:#ef4444'>Failed to fully parse DOCX: {e}</p>")
    html.append("</div>")
    return "".join(html)

def parse_pptx_to_html(content_bytes: bytes) -> str:
    html = ["<div style='font-family: \"Segoe UI\", Arial, sans-serif; padding: 20px;'>"]
    try:
        with zipfile.ZipFile(io.BytesIO(content_bytes)) as z:
            slide_files = [f for f in z.namelist() if f.startswith("ppt/slides/slide") and f.endswith(".xml")]
            slide_files.sort(key=lambda x: int(re.search(r'\d+', x).group()) if re.search(r'\d+', x) else 0)
            
            for slide in slide_files:
                html.append(f"<div style='border: 1px solid #334155; border-radius: 8px; margin-bottom: 24px; padding: 20px; background-color: #0f172a; box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.5);'>")
                html.append(f"<h3 style='color: #38bdf8; border-bottom: 1px solid #1e293b; padding-bottom: 10px; margin-top: 0;'>{slide.split('/')[-1]}</h3>")
                
                rels = {}
                rel_path = f"ppt/slides/_rels/{slide.split('/')[-1]}.rels"
                try:
                    rels_xml = z.read(rel_path)
                    for rel in ET.XML(rels_xml):
                        rId = rel.attrib.get('Id')
                        target = rel.attrib.get('Target')
                        if rId and target:
                            rels[rId] = target
                except Exception:
                    pass

                try:
                    tree = ET.XML(z.read(slide))
                    for p in tree.iter("{http://schemas.openxmlformats.org/drawingml/2006/main}p"):
                        texts = [t.text for t in p.iter("{http://schemas.openxmlformats.org/drawingml/2006/main}t") if t.text]
                        if texts:
                            html.append(f"<p style='margin: 8px 0; font-size: 16px;'>{''.join(texts)}</p>")
                    
                    for blip in tree.iter("{http://schemas.openxmlformats.org/drawingml/2006/main}blip"):
                        embed_id = blip.attrib.get("{http://schemas.openxmlformats.org/officeDocument/2006/relationships}embed")
                        if embed_id and embed_id in rels:
                            target = rels[embed_id]
                            img_name = target.split('/')[-1]
                            img_path = f"ppt/media/{img_name}"
                            try:
                                img_data = z.read(img_path)
                                b64 = base64.b64encode(img_data).decode('utf-8')
                                ext = img_name.split('.')[-1].lower()
                                mime = f"image/{ext}" if ext in ['png', 'jpeg', 'gif'] else "image/jpeg"
                                html.append(f"<div style='text-align: center; margin: 15px 0;'><img src='data:{mime};base64,{b64}' style='max-width:100%; max-height:400px; border-radius: 6px;'></div>")
                            except Exception:
                                pass
                except Exception as e:
                    html.append(f"<p style='color:#ef4444'>Slide parsing error: {e}</p>")
                html.append("</div>")
    except Exception as e:
        html.append(f"<p style='color:#ef4444'>Failed to fully parse PPTX: {e}</p>")
    html.append("</div>")
    return "".join(html)

def parse_xlsx_to_html(content_bytes: bytes) -> str:
    html = ["<div style='font-family: \"Segoe UI\", Arial, sans-serif; padding: 20px;'>"]
    try:
        with zipfile.ZipFile(io.BytesIO(content_bytes)) as z:
            shared_strings = []
            try:
                ss_tree = ET.XML(z.read("xl/sharedStrings.xml"))
                for t in ss_tree.iter("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}t"):
                    shared_strings.append(t.text or "")
            except Exception:
                pass
                
            sheet_files = [f for f in z.namelist() if f.startswith("xl/worksheets/sheet") and f.endswith(".xml")]
            sheet_files.sort(key=lambda x: int(re.search(r'\d+', x).group()) if re.search(r'\d+', x) else 0)
            
            for sheet in sheet_files:
                html.append(f"<div style='margin-bottom: 30px;'>")
                html.append(f"<h3 style='color: #10b981; margin-top: 0;'>{sheet.split('/')[-1]}</h3>")
                html.append("<table style='border-collapse: collapse; width: 100%; font-size: 14px;'>")
                try:
                    tree = ET.XML(z.read(sheet))
                    for row in tree.iter("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}row"):
                        html.append("<tr>")
                        for cell in row.iter("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}c"):
                            val = ""
                            v_node = cell.find("{http://schemas.openxmlformats.org/spreadsheetml/2006/main}v")
                            if v_node is not None and v_node.text:
                                if cell.attrib.get('t') == 's':
                                    idx = int(v_node.text)
                                    if idx < len(shared_strings):
                                        val = shared_strings[idx]
                                else:
                                    val = v_node.text
                            html.append(f"<td style='padding: 8px; border: 1px solid #334155;'>{val}</td>")
                        html.append("</tr>")
                except Exception as e:
                    html.append(f"<tr><td style='color:#ef4444'>Error reading sheet: {e}</td></tr>")
                html.append("</table></div>")
    except Exception as e:
        html.append(f"<p style='color:#ef4444'>Failed to fully parse XLSX: {e}</p>")
    html.append("</div>")
    return "".join(html)

def parse_openxml_to_html(filename: str, content_bytes: bytes) -> str:
    ext = filename.lower().split('.')[-1]
    if ext == 'docx': return parse_docx_to_html(content_bytes)
    if ext == 'pptx': return parse_pptx_to_html(content_bytes)
    if ext == 'xlsx': return parse_xlsx_to_html(content_bytes)
    return "<p>Unsupported Office OpenXML format</p>"
