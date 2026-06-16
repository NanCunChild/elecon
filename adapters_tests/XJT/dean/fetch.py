import requests
from bs4 import BeautifulSoup
import re
import time
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def fetch_xjtu_auto_bypass():
    url = 'https://dean.xjtu.edu.cn/'
    challenge_url = 'https://dean.xjtu.edu.cn/dynamic_challenge'
    
    # 保持 UA 和我们伪造的指纹一致 (Linux 平台)
    ua = 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36'
    
    headers = {
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
        'User-Agent': ua,
        'Referer': url # 有些 WAF 比较严格，带上同源 Referer 更好
    }

    # 使用 Session 来自动管理后续的 Cookie 状态
    session = requests.Session()
    session.headers.update(headers)

    try:
        # 第一步：裸奔请求，故意触发挑战页面
        print("[1/4] 发起初始请求，探测反爬机制...")
        res1 = session.get(url, timeout=10, verify=False)
        html = res1.text
        
        # 检查是否命中了 JS 挑战页面
        if 'var challengeId =' in html:
            print("[2/4] 触发动态挑战，正在解析密钥...")
            
            # 使用正则提取 challengeId 和 answer
            cid_match = re.search(r'var challengeId\s*=\s*"([^"]+)";', html)
            ans_match = re.search(r'var answer\s*=\s*(\d+);', html)
            
            if not cid_match or not ans_match:
                print("解析密钥失败，页面的正则结构可能已更改！")
                return
                
            cid = cid_match.group(1)
            ans = int(ans_match.group(1))
            
            # 伪造浏览器硬件指纹 (契合你的 Linux 环境配置)
            payload = {
                "challenge_id": cid,
                "answer": ans,
                "browser_info": {
                    "userAgent": ua,
                    "language": "zh-CN",
                    "platform": "Linux x86_64",
                    "cookieEnabled": True,
                    "hardwareConcurrency": 16, # 伪造一个高配 CPU
                    "deviceMemory": 16,        # 伪造 16GB 内存
                    "timezone": "Asia/Shanghai"
                }
            }
            
            # 完美模拟真实的等待时延 (源码中是 setTimeout(..., 800))
            time.sleep(0.8) 
            
            # 第二步：提交挑战换取 client_id
            print("[3/4] 提交指纹与哈希，换取通行证...")
            res2 = session.post(challenge_url, json=payload, verify=False)
            data = res2.json()
            
            if data.get('success'):
                # 提取并手动注入 Cookie
                client_id = data.get('client_id')
                session.cookies.set('client_id', client_id, domain='dean.xjtu.edu.cn', path='/')
                print(f"[*] 挑战通过！获得凭据: {client_id[:10]}...")
            else:
                print("服务器拒绝了我们的挑战响应:", data)
                return
        else:
            print("[2/4] 未遇到拦截，直接进入解析流程...")

        # 第三步：携带有效 Cookie，请求真实的首页
        print("[4/4] 正在拉取真实的通知列表数据...\n")
        res3 = session.get(url, timeout=10, verify=False)
        res3.encoding = res3.apparent_encoding
        final_html = res3.text
        
        # 第四步：执行我们之前写好的层级 DOM 解析
        soup = BeautifulSoup(final_html, 'html.parser')

        tz_blocks = soup.find_all('div', class_='tz')
        target_block = None
        for block in tz_blocks:
            if '通知公告' in block.text:
                target_block = block
                break
                
        if not target_block:
            print("未能定位到 div.tz，可能存在其他验证层或页面结构异动。")
            return

        print("=========== 西安交通大学 教务处通知 ===========")
        for li in target_block.find_all('li'):
            a_tag = li.find('a', title=True)
            if not a_tag:
                continue
            
            title = a_tag.get('title').strip()
            href = a_tag.get('href')
            full_link = href if href.startswith('http') else f"https://dean.xjtu.edu.cn/{href}"
            
            category_tag = li.find('i')
            category = category_tag.text.strip() if category_tag else ""
            
            date_tag = li.find('span')
            date_str = date_tag.text.strip() if date_tag else "未知"
            
            print(f"[{date_str}] {category} {title}")
            print(f"🔗 {full_link}")
        print("===============================================")

    except Exception as e:
        print(f"\n运行时发生网络或解析异常: {e}")

if __name__ == "__main__":
    fetch_xjtu_auto_bypass()