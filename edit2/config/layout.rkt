#lang racket

;;; config/layout.rkt —— 布局配置（**纯数据**，不 require 实现）
;;;
;;;   regions        (id side size (member ...))   区域；member 是面板 id
;;;   enabled-panels (panel-id ...)                装配时创建哪些面板
;;;   frame          骨架数据（编辑区 + 状态栏），由 core 解析成 Layout
;;;   editor-split-axis  编辑器拆分方向
;;;
;;; 面板 id（tree/buffers/status/log/help）由 core 的面板内容表决定；
;;; 这里只选「用哪些、放哪、多大」。加一个已支持的面板 = 改这里数据。

(provide regions enabled-panels frame editor-split-axis help-text)

(define regions
  '((sidebar left   28 (tree buffers))
    (log     bottom  6 (log))))

(define enabled-panels
  '(tree buffers status log help))

;; 根骨架：主区（区域往这里贴）+ 状态栏（全宽贴底）
(define frame
  '(split v
     ((flex (main (pane editor)))
      (1    (pane status)))))

(define editor-split-axis 'h)

(define help-text
  (string-append
   "edit2\n\n"
   " C-q 退出    C-s 保存    C-z/C-y 撤销/重做\n"
   " C-a/C-c/C-x/C-v  选区 / 剪贴板\n"
   " C-w 分屏    C-d 关窗口（资源保留）  C-b 侧栏显隐  C-l 日志  C-h 帮助\n"
   " 资源面板（树状：document 根 / view 子）：↑↓ 选，←→/空格 折叠，Enter 打开\n"
   "   C-d 关选中 view   Delete 关选中 document（连带其视图）\n"
   " 打开目标窗格：单窗直接替换；多窗进选择模式，鼠标/Tab/M-n 选，Enter 替换，Esc 取消\n"
   " M-t 侧栏=文件树   M-b 侧栏切换成员   M-e 编辑器\n"
   " M-n / M-p   焦点在窗格间循环\n"
   " 文件树里：↑↓ 移动，←→ 展开收起，Enter 打开\n"
   " 方向键/Home/End 移动，Enter/Backspace 编辑"))
