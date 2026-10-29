#!/usr/bin/env python3
# ============================================================
#  web/serve.py
#  ------------------------------------------------------------
#  起一个本地静态服务器（http://127.0.0.1:8765）并自动打开浏览器。
#
#  为什么要它：
#    Web Serial 需要"安全上下文"。Chrome 一般把 file:// 也当安全上下文，
#    但个别版本/策略下会不暴露 navigator.serial。用 localhost 打开最稳。
#
#  直接双击 web/启动控制台.cmd 即可（会自动调用本文件）。
#  也可以手动运行：  python web/serve.py
# ============================================================
import http.server
import os
import socketserver
import threading
import webbrowser

PORT = 8765
ROOT = os.path.dirname(os.path.abspath(__file__))


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def end_headers(self):
        # 改了 app.js / style.css 之后刷新就能看到，不会被缓存坑
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate')
        super().end_headers()

    def log_message(self, fmt, *args):
        pass


def main():
    url = f'http://127.0.0.1:{PORT}/index.html'
    print('=' * 58)
    print(' FPGA 合成器 · 网页控制台')
    print(f' 地址: {url}')
    print(' 关闭本窗口 = 停止服务器（不影响已经打开的页面）')
    print('=' * 58)

    # 等服务器起来再开浏览器
    threading.Timer(0.8, lambda: webbrowser.open(url)).start()

    try:
        with socketserver.ThreadingTCPServer(('127.0.0.1', PORT), Handler) as httpd:
            httpd.daemon_threads = True
            httpd.serve_forever()
    except OSError as e:
        print(f'端口 {PORT} 起不来：{e}')
        print('可能已经开着一个控制台了，直接用浏览器打开上面的地址即可。')
        input('按回车退出…')
    except KeyboardInterrupt:
        print('\n已停止。')


if __name__ == '__main__':
    main()
