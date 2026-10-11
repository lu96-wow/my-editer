#lang racket

;;; config/layout.rkt —— 布局配置（**纯数据**，不 require 实现）
;;;
;;;   regions        (id side size (member ...) [anchor])   区域；member 是面板 id
;;                  anchor = root（贴根，跨满整屏）| main（贴主区，让开状态栏，默认）
;;;   enabled-panels (panel-id ...)                装配时创建哪些面板
;;;   frame          骨架数据（编辑区 + 状态栏），由 core 解析成 Layout
;;;
;;; 面板 id（tree/buffers/status/log/help）由 core 的面板内容表决定；
;;; 这里只选「用哪些、放哪、多大」。加一个已支持的面板 = 改这里数据。

(provide regions enabled-panels frame help-text
         border-style borders-on?)

;; 侧栏贴根 → 占满左侧整高；日志贴主区 → 让开底部状态栏。
(define regions
  '((sidebar left   28 (tree buffers) root)
    (log     bottom  6 (log))))

(define enabled-panels
  '(tree buffers status log help))

;; 根骨架：主区（区域往这里贴）+ 状态栏（全宽贴底）
;; 状态栏给 2 行：它自身的边框顶边与主区的底边合并（只画一条线），
;; 剩下 1 行内容 + 1 行底边；于是状态栏被包在边框内，而不是悬在边框外。
(define frame
  '(split v
     ((flex (main (pane editor)))
      (2    (pane status)))))

;; 边框：默认是否给新窗口加，以及用哪个命名 face（见 core/theme.rkt）。
(define borders-on? #t)
(define border-style 'window-border)

(define help-text
  (string-append
   "edit2\n\n"
   " C-q 退出    M-s 保存    C-z/C-y 撤销/重做\n"
   " C-a/C-c/C-x/C-v  选区 / 剪贴板\n"
   " C-s ↑/↓ 上/下堆叠  C-s ←/→ 左右并排（新窗留空）    C-d 关窗口    C-t 边框开关    C-b 侧栏显隐  C-l 日志  M-h 帮助\n"
   " 资源面板（树状：document 根 / view 子）：↑↓ 选，←→/空格 折叠，Enter 打开，n 新建 view\n"
   "   C-d 关选中 view   Delete 关选中 document（连带其视图）\n"
   " 打开目标窗格：单窗直接替换；多窗进选择模式，鼠标/Tab/M-n 选，Enter 替换，Esc 取消\n"
   " M-t 侧栏=文件树   M-b 侧栏切换成员   M-e 编辑器\n"
   " M-n / M-p   焦点在窗格间循环\n"
   " 文件树：顶行 = 工作区根；↑↓←→ 移动光标（普通光标），Enter 展开/折叠（文件则打开）\n"
   "   C-n f 新文件   C-n C-n f 新目录   C-d 删除（确认）   C-u 重读磁盘   C-h 隐藏项显/隐\n"
   " 方向键/Home/End 移动，Enter/Backspace 编辑"))
