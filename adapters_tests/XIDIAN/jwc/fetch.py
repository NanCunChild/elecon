import requests
from bs4 import BeautifulSoup

def fetch_notices():
    # 目标URL (假设在首页)
    url = 'https://jwc.xidian.edu.cn/' 
    
    headers = {
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36',
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9'
    }

    try:
        # 发送 GET 请求，设置较短的超时时间
        response = requests.get(url, headers=headers, timeout=10)
        # 防止中文乱码，手动指定编码（根据网站实际情况，通常是 utf-8 或 gb2312）
        response.encoding = 'utf-8' 
        
        # 如果返回状态码不是 200，抛出异常
        response.raise_for_status() 
        
    except requests.RequestException as e:
        print(f"请求网页失败: {e}")
        return

    # 使用 bs4 解析 HTML
    soup = BeautifulSoup(response.text, 'html.parser')

    # 1. 核心定位逻辑：先找到包含 "通知公告" 这四个字的 a 标签
    target_a_tag = soup.find('a', string='通知公告')
    
    if not target_a_tag:
        print("未在页面中找到'通知公告'的锚点。")
        return

    # 2. 向上找到它的容器 div.tit
    tit_div = target_a_tag.find_parent('div', class_='tit')
    
    if tit_div:
        # 3. 寻找紧跟在这个 div 后面的 ul 列表
        ul_tag = tit_div.find_next_sibling('ul')
        
        if ul_tag:
            # 4. 遍历 ul 中的所有 li 标签提取数据
            for li in ul_tag.find_all('li'):
                a_tag = li.find('a')
                if not a_tag:
                    continue
                
                # 提取标题和相对链接
                title = a_tag.get('title')
                href = a_tag.get('href')
                
                # 拼接完整的绝对路径链接
                full_link = href if href.startswith('http') else f"https://jwc.xidian.edu.cn/{href}"
                
                # 提取时间 (注意 HTML 中有两种 class: 'time' 和 'time lan')
                # 我们可以模糊匹配，只要 div 的 class 中包含 time 即可
                time_div = a_tag.find('div', class_=lambda c: c and 'time' in c)
                
                if time_div:
                    day = time_div.find('p').text.strip()
                    year_month = time_div.find('span').text.strip()
                    full_date = f"{year_month}.{day}"
                else:
                    full_date = "未知时间"
                
                # 打印结果
                print(f"[{full_date}] {title}")
                print(f"链接: {full_link}\n")
                
if __name__ == "__main__":
    fetch_notices()