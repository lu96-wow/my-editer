#lang racket

;;; demo.rkt —— 手动测试用：在终端里跑起编辑器（组装根）
;;;
;;; 运行：  racket demo.rkt          （需要 Linux 终端；非 tty 会报错）
;;; 按键：
;;;   Ctrl+Q 退出 / Ctrl+W 切换折行
;;;   Ctrl+V 上下分屏 / Ctrl+B 左右分屏 / Ctrl+X 关当前窗
;;;   Ctrl+O 下一窗口 / Ctrl+P 上一窗口
;;;
;;; 可测：
;;;   - 中英文混排 / emoji / 全角标点（宽字符显示与光标定位）
;;;   - 直接打字、退格、回车、方向键、Home/End、PageUp/PageDown
;;;   - 鼠标点击定位光标、滚轮滚动
;;;   - 语法高亮（关键字蓝 / 字符串绿 / 注释灰），随编辑实时刷新
;;;   - 诊断标注：源码里故意留了一处语法错误 (define broken)，红字显示
;;;   - 分屏后两个窗口共享同一 buffer，一处编辑两处同步；窗口间有 | / - 边框

(require "core/text/buffer.rkt"
         "framework/slots.rkt" "framework/framework.rkt"
         "reference/layout-tree.rkt" "reference/compose-line.rkt"
         "reference/commands.rkt" "ui/tui/tui.rkt"
         "plugin-reference/racket-hl.rkt" "plugin-reference/status.rkt"
         "plugin-reference/auto-pair.rkt" "plugin-reference/indent.rkt"
         "plugin-reference/racket-diag.rkt")

(provide sample)

;;; ---------- 示例内容 ----------

(define sample
  (string-join
   (list
    "#lang racket"
    ";; 编辑器 demo —— 中英文混排：你好世界 hello，宽字符 😀😃🎉，全角标点，。！？"
    "(define (square x) (* x x))"
    "(define (double x) (* 2 x))"
    "(lambda (y) (if (> y 0) y 0))"
    "(define msg \"hello 你好 😀\") ; 字符串里的宽字符"
    ""
    ";; ↓ 故意留一个语法错误：define 缺表达式，应显示为红字"
    "(define broken)"
    ""
    ";; 操作：方向键 / 打字 / 退格 / 回车；Ctrl+Q 退出 / Ctrl+W 切换折行"
    ";; 折行：这段很长很长的中文文本用来测试 wrap 模式下自动折行的显示效果")
   "\n"))

;;; ---------- 主题（纯数据，外部组合时定义并传入）----------

(define demo-theme
  (hash 'keyword '(97 175 239)        ; 蓝
        'string  '(152 195 121)       ; 绿
        'comment '(128 128 128 dim)
        'number  '(198 120 221)       ; 紫
        'builtin '(86 182 194)        ; 青
        'mode    '(229 192 123)       ; 黄
        'border  '(92 99 112 dim)     ; 边框灰
        'error   '(255 100 100)        ; 诊断错误：红
        'warning '(229 192 123)))

;;; ---------- 组装（用户拼出界面）----------

(define-values (wc fc) (make-default-commands))
(define ap-wc (auto-pair-strategy wc))

(define cfg
  (make-config
   #:window-commands ap-wc
   #:frame-commands  fc
   #:layout          tree-layout
   #:compose         line-compose
   #:edit-plugins    (list (edit-plugin-spec 'indent indent-on-enter '() 'sync))
   #:plugins         (list (plugin-spec 'keyword-hl keyword-hl '() 'sync)
                           (plugin-spec 'racket-diag racket-diag '() 'sync))
   #:view-plugins    (list rowcol-status)
   #:theme           demo-theme))

;;; ---------- 启动（仅当直接运行 demo.rkt 时）----------

(module+ main
  (displayln "启动 TUI demo（Ctrl+Q 退出 / Ctrl+V|B 分屏 / Ctrl+O|P 切窗 / Ctrl+X 关窗）…")
  (run-tui (buffer-open sample) cfg))
