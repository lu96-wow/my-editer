#lang racket

;;; edit-tui/config/help/default.rkt —— 默认帮助 buffer 数据
;;;
;;; 这是 configuration / 静态数据；buffer 创建和打开由 app/bootstrap + host/help 负责。

(provide help-doc-id
         help-view-id
         help-buffer-name
         help-text)

(define help-doc-id 9)
(define help-view-id 9)
(define help-buffer-name "*help*")

(define help-text
  #<<HELP
edit 快捷键
===========

帮助
  C-x h            打开 / 聚焦本帮助 buffer

编辑
  直接打字         插入
  Enter            换行 + 当前行对齐
  Tab              插入两个空格
  Backspace        删前
  Delete           删后
  ←→↑↓ Home End    移动
  Shift+方向       扩选
  PageUp/Down      翻页
  C-a              行首
  C-f              右移
  C-k              删到行尾
  C-z / C-y        撤销 / 重做

查找 / 替换
  C-x f            查找当前 buffer
  C-left / C-right 上一个 / 下一个匹配
  C-x c f          选中文本作为源，完整匹配全局替换
  C-x c s          选中文本作为源，子字符串全局替换

布局
  C-w ←→↑↓         拆分当前 editor
  C-x ←→↑↓         焦点在 editor panel 间移动
  C-w d            关闭当前 editor panel
  C-w c            进入 resize 模式
    ←→↑↓           变窄 / 变宽 / 变高 / 变矮
    C-b / Esc      退出 resize 模式
  C-b              显 / 隐 sidebar（resize 模式外）
  C-x b            切换 sidebar tab（filetree / resources）
  C-x n / C-x p    下一个 / 上一个 editor tab

文件 / 会话
  C-s              保存 / save-as / 确认
  C-q q            退出，不保存会话状态
  C-q s            保存会话状态并退出
  C-x k            关闭当前 buffer
  M-0..M-9         切到编辑区 0..9

面板 / 文档
  C-e              开关 error panel
  C-x d            显 / 隐 docs panel
  M-d              查看光标处标识符文档
  M-l              双语：打开 / 聚焦 / 关闭当前 Racket buffer 的 mirror

补全
  C-o              手动打开补全
  Up / Down        移动候选
  Tab              下一个候选
  Enter            接受候选
  Esc / C-g        关闭补全

filetree
  Enter            打开文件
  C-r              刷新
  C-h              显 / 隐 dotfile
  C-f s            递归查找
  C-f n            新建文件
  C-f C-f n        新建目录
  C-f r            重命名
  C-f d            删除

鼠标
  点 panel         聚焦 + 光标落点
  拖接缝           resize
  滚轮             滚动指针下 panel
HELP
  )
