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
;;;   - 分屏后两个窗口共享同一 buffer，一处编辑两处同步；窗口间有 | / - 边框

(require "core/text/buffer.rkt" "core/text/patch.rkt"
         "core/view/window.rkt" "core/text/cursor.rkt"
         "framework/slots.rkt" "framework/framework.rkt"
         "reference/layout-tree.rkt" "reference/compose-line.rkt"
         "reference/commands.rkt" "ui/tui/tui.rkt")

(provide sample keyword-hl rowcol-status)

;;; ---------- 演示用语法高亮插件（就地定义，属 demo 不属核心）----------

(define keyword-rx #px"\\b(define|lambda|if|cond|let|for|match|and|or|not)\\b")
(define string-rx  #px"\"[^\"]*\"")
(define comment-rx #px";[^\n]*")

(define (matches->segs line rx face text)
  (for/list ([m (in-list (regexp-match-positions* rx text))])
    (list line (car m) (cdr m) face)))

;; 语法高亮插件：buffer -> (listof patch)，纯、不知道线程。
;; 每个 dirty 行产出一个 patch：先清该行 'face 旧值，再写新 segs。
(define (keyword-hl b)
  (define d (buffer-dirty b))
  (if (not d)
      '()
      (for/list ([line (in-range (dirty-desc-first-line d)
                                 (add1 (dirty-desc-last-line d)))])
        (define text (buffer-line-ref b line))
        (patch 'face line line
               (append
                (matches->segs line keyword-rx 'keyword text)
                (matches->segs line string-rx  'string  text)
                (matches->segs line comment-rx 'comment text))))))

;;; ---------- 演示用 view 插件：状态行（行列 + 模式）----------

(define (rowcol-status w)
  (define p (window-point w))
  (define line-count (buffer-line-count (window-buffer w)))
  (list
   (status-seg (format "Ln ~a, Col ~a" (add1 (cursor-line p)) (add1 (cursor-col p))) #f)
   (status-seg "  " #f)
   (status-seg (if (eq? (window-mode w) 'wrap) "wrap" "clip") 'mode)
   (status-seg (format "  ~a 行" line-count) #f)))

;;; ---------- 示例内容 ----------

(define sample
  (string-join
   (list
    ";; 编辑器核心 demo —— 中英文混排测试"
    "你好世界 hello world 你好"
    "(define (square x) (* x x))"
    "(lambda (y) (if (> y 0) y 0))"
    "中文测试：宽字符占两列，光标定位应正确。"
    "emoji 测试：😀😃🎉 和全角标点，。！？"
    "字符串测试 \"hello 你好 😀\" 注释 ; 这是注释"
    "折行测试：这是一段很长很长的中文文本用来测试折行模式下的显示效果超过终端宽度时会被自动折成多行显示。"
    ""
    "方向键移动 / 直接打字 / 退格 / 回车"
    "Ctrl+Q 退出 / Ctrl+W 切换折行")
   "\n"))

;;; ---------- 主题（纯数据，外部组合时定义并传入）----------

(define demo-theme
  (hash 'keyword '(97 175 239)        ; 蓝
        'string  '(152 195 121)       ; 绿
        'comment '(128 128 128 dim)
        'number  '(198 120 221)       ; 紫
        'builtin '(86 182 194)        ; 青
        'mode    '(229 192 123)       ; 黄
        'border  '(92 99 112 dim)))   ; 边框灰

;;; ---------- 组装（用户拼出界面）----------

(define-values (wc fc) (make-default-commands))

(define cfg
  (make-config
   #:window-commands wc
   #:frame-commands  fc
   #:layout          tree-layout
   #:compose         line-compose
   #:plugins         (list (plugin-spec 'keyword-hl keyword-hl '() 'sync))
   #:view-plugins    (list rowcol-status)
   #:theme           demo-theme))

;;; ---------- 启动（仅当直接运行 demo.rkt 时）----------

(module+ main
  (displayln "启动 TUI demo（Ctrl+Q 退出 / Ctrl+V|B 分屏 / Ctrl+O|P 切窗 / Ctrl+X 关窗）…")
  (run-tui (buffer-open sample) cfg))
