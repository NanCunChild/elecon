import requests
from bs4 import BeautifulSoup
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def fetch_notices_fixed():
    url = 'https://jwc.xidian.edu.cn/' 
    headers = {
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.3770.100 Safari/537.36'
    }

    try:
        response = requests.get(url, headers=headers, timeout=10, verify=False)
        response.raise_for_status() 
        response.encoding = response.apparent_encoding
        
        soup = BeautifulSoup(response.text, 'html.parser')

        # 【核心修改点】
        # 1. 找到页面上所有 class 为 'tit' 的 div
        tit_divs = soup.find_all('div', class_='tit')
        
        target_tit_div = None
        # 2. 遍历这些 div，看看哪一个里面包含“通知公告”这几个字
        for div in tit_divs:
            if '通知公告' in div.text:
                target_tit_div = div
                break  # 找到了目标容器，跳出循环
                
        if not target_tit_div:
            print("未能找到包含 '通知公告' 标题的区块。")
            return

        # 3. 找到该标题区块紧挨着的下一个 <ul> 列表
        ul_tag = target_tit_div.find_next_sibling('ul')
        
        if not ul_tag:
            print("找到了标题，但后面没有跟着 <ul> 列表内容。")
            return

        # 4. 正常遍历列表提取数据
        print("--- 抓取到的通知列表 ---")
        for li in ul_tag.find_all('li'):
            a_tag = li.find('a')
            if not a_tag:
                continue
            
            # 提取标题，优先拿 title 属性，如果没有就拿文本
            title = a_tag.get('title', a_tag.text.strip())
            href = a_tag.get('href', '')
            full_link = href if href.startswith('http') else f"https://jwc.xidian.edu.cn/{href}"
            
            # 提取日期
            time_div = a_tag.find('div', class_=lambda c: c and 'time' in c)
            if time_div:
                day = time_div.find('p').text.strip() if time_div.find('p') else ''
                year_month = time_div.find('span').text.strip() if time_div.find('span') else ''
                full_date = f"{year_month}.{day}"
            else:
                full_date = "未知时间"
            
            print(f"[{full_date}] {title}")
            print(f"🔗 {full_link}\n")

    except Exception as e:
        print(f"抓取发生错误: {e}")

if __name__ == "__main__":
    fetch_notices_fixed()