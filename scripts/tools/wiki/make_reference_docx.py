# scripts/tools/wiki/make_reference_docx.py
"""Build the pandoc reference.docx used for the BIOME-CALC wiki guides.

Starts from pandoc's own default reference.docx (passed as argv[1]) and patches
styles and page setup with the standard library only (no python-docx).
Usage: make_reference_docx.py <pandoc-default-reference.docx> <out.docx> <footer text>
"""
import re
import sys
import zipfile
from xml.sax.saxutils import escape

ACCENT = "1F5C4A"
FONT = "Arial"
MONO = "Consolas"

W_NS = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"'
R_NS = 'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'


def replace_style(styles: str, style_id: str, new_xml: str) -> str:
    pattern = re.compile(r'<w:style [^>]*w:styleId="%s".*?</w:style>' % style_id, re.S)
    if pattern.search(styles):
        return pattern.sub(lambda _m: new_xml, styles, count=1)
    return styles.replace("</w:styles>", new_xml + "</w:styles>")


def heading(style_id: str, name: str, level: int, size: int, before: int, page_break: bool) -> str:
    pb = "<w:pageBreakBefore/>" if page_break else ""
    return (
        f'<w:style w:type="paragraph" w:styleId="{style_id}"><w:name w:val="{name}"/>'
        '<w:basedOn w:val="Normal"/><w:next w:val="BodyText"/><w:uiPriority w:val="9"/><w:qFormat/>'
        f'<w:pPr><w:keepNext/><w:keepLines/>{pb}<w:spacing w:before="{before}" w:after="120"/>'
        f'<w:outlineLvl w:val="{level}"/></w:pPr>'
        f'<w:rPr><w:rFonts w:ascii="{FONT}" w:hAnsi="{FONT}" w:cs="{FONT}"/><w:b/><w:bCs/>'
        f'<w:color w:val="{ACCENT}"/><w:sz w:val="{size}"/><w:szCs w:val="{size}"/></w:rPr></w:style>'
    )


def patch_styles(styles: str) -> str:
    styles = re.sub(
        r"<w:rPrDefault>.*?</w:rPrDefault>",
        f'<w:rPrDefault><w:rPr><w:rFonts w:ascii="{FONT}" w:eastAsia="{FONT}" w:hAnsi="{FONT}" w:cs="{FONT}"/>'
        '<w:sz w:val="21"/><w:szCs w:val="21"/><w:lang w:val="en-GB" w:eastAsia="en-US" w:bidi="ar-SA"/>'
        "</w:rPr></w:rPrDefault>",
        styles,
        count=1,
        flags=re.S,
    )
    styles = replace_style(styles, "Heading1", heading("Heading1", "heading 1", 0, 34, 0, True))
    styles = replace_style(styles, "Heading2", heading("Heading2", "heading 2", 1, 28, 360, False))
    styles = replace_style(styles, "Heading3", heading("Heading3", "heading 3", 2, 24, 240, False))
    styles = replace_style(styles, "Heading4", heading("Heading4", "heading 4", 3, 22, 200, False))
    styles = replace_style(
        styles,
        "Title",
        '<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/>'
        '<w:next w:val="BodyText"/><w:qFormat/><w:pPr>'
        f'<w:pBdr><w:bottom w:val="single" w:sz="12" w:space="8" w:color="{ACCENT}"/></w:pBdr>'
        '<w:spacing w:before="2400" w:after="240"/></w:pPr>'
        f'<w:rPr><w:rFonts w:ascii="{FONT}" w:hAnsi="{FONT}"/><w:b/><w:color w:val="{ACCENT}"/>'
        '<w:sz w:val="52"/><w:szCs w:val="52"/></w:rPr></w:style>',
    )
    styles = replace_style(
        styles,
        "Subtitle",
        '<w:style w:type="paragraph" w:styleId="Subtitle"><w:name w:val="Subtitle"/><w:basedOn w:val="Title"/>'
        '<w:next w:val="BodyText"/><w:qFormat/><w:pPr><w:pBdr/><w:spacing w:before="120" w:after="480"/></w:pPr>'
        '<w:rPr><w:b w:val="0"/><w:color w:val="444444"/><w:sz w:val="30"/><w:szCs w:val="30"/></w:rPr></w:style>',
    )
    styles = replace_style(
        styles,
        "SourceCode",
        '<w:style w:type="paragraph" w:customStyle="1" w:styleId="SourceCode"><w:name w:val="Source Code"/>'
        '<w:basedOn w:val="Normal"/><w:link w:val="VerbatimChar"/><w:pPr>'
        '<w:pBdr><w:left w:val="single" w:sz="18" w:space="6" w:color="9DB8AE"/></w:pBdr>'
        '<w:shd w:val="clear" w:color="auto" w:fill="F4F6F5"/><w:wordWrap w:val="off"/><w:spacing w:before="60" w:after="160"/>'
        '<w:ind w:left="170"/></w:pPr>'
        f'<w:rPr><w:rFonts w:ascii="{MONO}" w:hAnsi="{MONO}" w:cs="{MONO}"/><w:sz w:val="17"/><w:szCs w:val="17"/></w:rPr></w:style>',
    )
    styles = replace_style(
        styles,
        "VerbatimChar",
        '<w:style w:type="character" w:customStyle="1" w:styleId="VerbatimChar"><w:name w:val="Verbatim Char"/>'
        f'<w:rPr><w:rFonts w:ascii="{MONO}" w:hAnsi="{MONO}" w:cs="{MONO}"/><w:sz w:val="18"/>'
        '<w:shd w:val="clear" w:color="auto" w:fill="F0F2F1"/></w:rPr></w:style>',
    )
    styles = replace_style(
        styles,
        "Hyperlink",
        '<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/>'
        '<w:rPr><w:color w:val="1A5FA8"/><w:u w:val="single"/></w:rPr></w:style>',
    )
    styles = replace_style(
        styles,
        "BlockText",
        '<w:style w:type="paragraph" w:styleId="BlockText"><w:name w:val="Block Text"/><w:basedOn w:val="BodyText"/>'
        '<w:pPr><w:pBdr><w:left w:val="single" w:sz="24" w:space="8" w:color="D9A441"/></w:pBdr>'
        '<w:shd w:val="clear" w:color="auto" w:fill="FBF6EA"/><w:ind w:left="227" w:right="113"/></w:pPr>'
        "</w:style>",
    )
    styles = replace_style(
        styles,
        "WikiTOCTitle",
        '<w:style w:type="paragraph" w:customStyle="1" w:styleId="WikiTOCTitle"><w:name w:val="Wiki TOC Title"/>'
        '<w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:pPr><w:pageBreakBefore/><w:spacing w:after="240"/></w:pPr>'
        f'<w:rPr><w:b/><w:color w:val="{ACCENT}"/><w:sz w:val="34"/><w:szCs w:val="34"/></w:rPr></w:style>',
    )
    for level, indent, extra in ((1, 0, "<w:b/>"), (2, 340, "")):
        styles = replace_style(
            styles,
            f"WikiTOC{level}",
            f'<w:style w:type="paragraph" w:customStyle="1" w:styleId="WikiTOC{level}"><w:name w:val="Wiki TOC {level}"/>'
            f'<w:basedOn w:val="Normal"/><w:pPr><w:spacing w:before="{80 if level == 1 else 0}" w:after="20"/>'
            f'<w:ind w:left="{indent}"/></w:pPr><w:rPr>{extra}<w:sz w:val="20"/></w:rPr></w:style>',
        )
    border = '<w:{side} w:val="single" w:sz="4" w:space="0" w:color="B7C4BF"/>'
    borders = "".join(border.format(side=s) for s in ("top", "left", "bottom", "right", "insideH", "insideV"))
    styles = replace_style(
        styles,
        "Table",
        '<w:style w:type="table" w:default="1" w:styleId="Table"><w:name w:val="Table"/>'
        '<w:basedOn w:val="TableNormal"/><w:qFormat/><w:pPr><w:spacing w:before="40" w:after="40"/></w:pPr>'
        '<w:rPr><w:sz w:val="18"/><w:szCs w:val="18"/></w:rPr>'
        f'<w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblBorders>{borders}</w:tblBorders>'
        '<w:tblCellMar><w:top w:w="40" w:type="dxa"/><w:left w:w="100" w:type="dxa"/>'
        '<w:bottom w:w="40" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr>'
        '<w:tblStylePr w:type="firstRow"><w:rPr><w:b/><w:bCs/></w:rPr>'
        '<w:tcPr><w:shd w:val="clear" w:color="auto" w:fill="E3ECE8"/></w:tcPr></w:tblStylePr></w:style>',
    )
    return styles


def footer_xml(text: str) -> str:
    field = (
        '<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> {0} </w:instrText></w:r>'
        '<w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>'
    )
    return (
        f'<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:ftr {W_NS} {R_NS}>'
        '<w:p><w:pPr><w:pBdr><w:top w:val="single" w:sz="4" w:space="4" w:color="B7C4BF"/></w:pBdr>'
        '<w:tabs><w:tab w:val="right" w:pos="9638"/></w:tabs></w:pPr>'
        f'<w:r><w:rPr><w:color w:val="666666"/><w:sz w:val="16"/></w:rPr><w:t xml:space="preserve">{escape(text)}</w:t></w:r>'
        '<w:r><w:rPr><w:sz w:val="16"/></w:rPr><w:tab/><w:t xml:space="preserve">Page </w:t></w:r>'
        + field.format("PAGE")
        + '<w:r><w:t xml:space="preserve"> of </w:t></w:r>'
        + field.format("NUMPAGES")
        + "</w:p></w:ftr>"
    )


SECT_PR = (
    '<w:sectPr><w:footerReference w:type="default" r:id="rIdWikiFooter"/>'
    '<w:pgSz w:w="11906" w:h="16838"/>'
    '<w:pgMar w:top="1134" w:right="1134" w:bottom="1134" w:left="1134" w:header="567" w:footer="567" w:gutter="0"/>'
    "</w:sectPr>"
)


def main() -> int:
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    src, dst, footer_text = sys.argv[1], sys.argv[2], sys.argv[3]
    with zipfile.ZipFile(src) as zin, zipfile.ZipFile(dst, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            if not item.filename.endswith((".xml", ".rels")):
                zout.writestr(item, zin.read(item.filename))
                continue
            data = zin.read(item.filename).decode("utf-8")
            if item.filename == "word/styles.xml":
                data = patch_styles(data)
            elif item.filename == "word/document.xml":
                data = re.sub(r"<w:sectPr\s*/>|<w:sectPr>.*?</w:sectPr>", SECT_PR, data, count=1, flags=re.S)
            elif item.filename == "word/_rels/document.xml.rels":
                data = data.replace(
                    "</Relationships>",
                    '<Relationship Id="rIdWikiFooter" '
                    'Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" '
                    'Target="footer1.xml"/></Relationships>',
                )
            elif item.filename == "[Content_Types].xml":
                data = data.replace(
                    "</Types>",
                    '<Override PartName="/word/footer1.xml" '
                    'ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/></Types>',
                )
            zout.writestr(item, data)
        zout.writestr("word/footer1.xml", footer_xml(footer_text))
    return 0


if __name__ == "__main__":
    sys.exit(main())
