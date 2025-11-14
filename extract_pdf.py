#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
PDF文本提取脚本
用于提取Uniswap V3白皮书PDF中的文本内容
"""

try:
    import PyPDF2
    HAS_PYPDF2 = True
except ImportError:
    HAS_PYPDF2 = False

try:
    import pdfplumber
    HAS_PDFPLUMBER = True
except ImportError:
    HAS_PDFPLUMBER = False

def extract_text_pypdf2(pdf_path):
    """使用PyPDF2提取文本"""
    text = ""
    with open(pdf_path, 'rb') as file:
        pdf_reader = PyPDF2.PdfReader(file)
        for page_num, page in enumerate(pdf_reader.pages):
            text += f"\n--- Page {page_num + 1} ---\n"
            text += page.extract_text()
    return text

def extract_text_pdfplumber(pdf_path):
    """使用pdfplumber提取文本（更准确）"""
    text = ""
    with pdfplumber.open(pdf_path) as pdf:
        for page_num, page in enumerate(pdf.pages):
            text += f"\n--- Page {page_num + 1} ---\n"
            page_text = page.extract_text()
            if page_text:
                text += page_text
    return text

def main():
    pdf_path = "contracts/note/whitepaper-v3.pdf"
    output_path = "contracts/note/whitepaper-v3-extracted.txt"
    
    print("正在提取PDF文本...")
    
    if HAS_PDFPLUMBER:
        print("使用pdfplumber提取...")
        text = extract_text_pdfplumber(pdf_path)
    elif HAS_PYPDF2:
        print("使用PyPDF2提取...")
        text = extract_text_pypdf2(pdf_path)
    else:
        print("错误：未安装PDF处理库")
        print("请运行: pip install pdfplumber 或 pip install PyPDF2")
        return
    
    # 保存提取的文本
    with open(output_path, 'w', encoding='utf-8') as f:
        f.write(text)
    
    print(f"文本已提取到: {output_path}")
    print(f"共提取 {len(text)} 个字符")

if __name__ == "__main__":
    main()

