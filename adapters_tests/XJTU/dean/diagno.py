import requests
from bs4 import BeautifulSoup

def debug_xjtu():
    url = 'https://dean.xjtu.edu.cn/' 
    headers = {
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36'
    }

    response = requests.get(url, headers=headers, timeout=10)
    response.encoding = response.apparent_encoding
    
    soup = BeautifulSoup(response.text, 'html.parser')
    
    print("=== 诊断信息 ===")
    print(f"实际返回的状态码: {response.status_code}")
    print(f"网页标题 (Title): {soup.title.text.strip() if soup.title else '无标题'}")
    print("网页源码不输出；原始探针材料只能写入仓库 .private-probes/。")

if __name__ == "__main__":
    debug_xjtu()
