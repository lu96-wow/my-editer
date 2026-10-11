#lang racket

;;; edit2/theme.rkt —— 命名样式表（face 名字 → 真彩色 / 256 色）
;;;
;;; 编辑器里所有样式都用**命名 face**（符号）：'window-border、'status、'tree-dir …。
;;; 本模块把名字映射到具体颜色 + 属性，再翻成 ANSI 字节；后端只调 attr-bytes。
;;;
;;; core 的 piece-attr 形态：
;;;   (render face)      普通文本格，face = 名字（符号）| #f
;;;   (cursor . face)    光标格
;;;   (selection . face) 选区格

(provide style style-fg style-bg style-attrs
         face-bytes attr-bytes
         theme-ref)

(require (prefix-in t: tui))

;;; ---------- 样式值 ----------

(struct style (fg bg attrs) #:transparent)
;; fg / bg : #f（终端默认）| (rgb r g b) 真彩色 | 0..255 的整数（256 色）
;; attrs   : (listof 'bold | 'dim | 'italic | 'underline)

(define (rgb r g b) (list 'rgb r g b))

;; 命名样式表：名字 → style。加一个样式 = 这里加一行。配色沿用 edit 的 tree/state 方案。
(define palette
  (hash
   'default        (style #f #f '())
   'dim            (style (rgb 120 120 130) #f '())
   'bold           (style #f #f '(bold))
   'italic         (style #f #f '(italic))
   'underline      (style #f #f '(underline))
   'accent         (style (rgb 120 180 240) #f '())
   ;; 窗口 / 边框
   'window-border  (style (rgb 105 112 128) #f '())
   ;; 状态行 / 消息 / 输入
   'status-bar     (style (rgb 225 225 225) (rgb 40 44 52) '())   ; 状态行
   'status-mode    (style (rgb 120 210 130) #f '(bold))           ; 模式 / 文档名
   'status-dirty   (style (rgb 230 160 90) #f '(bold))            ; 未保存标记
   'message        (style (rgb 230 160 90) #f '())                ; 提示 / 错误
   'input          (style (rgb 20 20 20) (rgb 230 200 90) '())    ; 输入行
   'log            (style (rgb 235 188 110) #f '())               ; 日志行
   ;; 文件树
   'tree-dir       (style (rgb 120 180 240) #f '())               ; 目录：蓝
   'tree-file      (style (rgb 200 200 200) #f '())               ; 文件：灰白
   'tree-link      (style (rgb 120 200 200) #f '())               ; 符号链接：青
   'tree-hidden    (style (rgb 120 120 130) #f '())               ; 隐藏项：暗
   'tree-open      (style (rgb 120 210 130) #f '(bold))           ; 已打开：绿粗
   'tree-match     (style (rgb 220 190 120) #f '())               ; 查询命中：黄
   'tree-current   (style (rgb 20 20 20) (rgb 230 200 90) '())    ; 当前命中：黄底
   ;; 资源面板（buffers）
   'buf-current    (style (rgb 120 210 130) #f '(bold))           ; 当前文档
   'buf-file       (style (rgb 200 200 200) #f '())               ; 其它文档
   'buf-untitled   (style (rgb 170 170 170) #f '())               ; 无路径
   'buf-view       (style (rgb 140 160 190) #f '())               ; 视图行
   'buf-dirty      (style (rgb 230 160 90) #f '(bold))))          ; 脏文档

(define (theme-ref name) (hash-ref palette name #f))

;;; ---------- 颜色 → ANSI ----------

(define (color-bytes fg? c)
  (cond
    [(not c) #""]
    [(and (pair? c) (eq? (car c) 'rgb))
     (if fg? (t:format-rgb-fg-base (cadr c) (caddr c) (cadddr c))
             (t:format-rgb-bg-base (cadr c) (caddr c) (cadddr c)))]
    [(exact-nonnegative-integer? c)
     (if fg? (t:format-256-fg-base c) (t:format-256-bg-base c))]
    [else #""]))

(define attr-table
  (hash 'bold t:format-bold 'dim t:format-dim 'italic t:format-italic 'underline t:format-underline))

(define (style-bytes st)
  (bytes-append
   (color-bytes #t (style-fg st))
   (color-bytes #f (style-bg st))
   (apply bytes-append (for/list ([a (in-list (style-attrs st))]) (hash-ref attr-table a #"")))))

;;; ---------- face → 字节 ----------

(define (face-bytes f)
  (cond
    [(not f) #""]
    [(style? f) (style-bytes f)]
    [(symbol? f) (define st (theme-ref f)) (if st (style-bytes st) #"")]
    [else #""]))

(define (attr-bytes attr)
  (cond
    [(and (pair? attr) (eq? (car attr) 'cursor))    (bytes-append (face-bytes (cdr attr)) t:format-reverse)]
    [(and (pair? attr) (eq? (car attr) 'selection)) (bytes-append (face-bytes (cdr attr)) t:format-reverse)]
    [(and (pair? attr) (eq? (car attr) 'render))    (face-bytes (cadr attr))]
    [else (face-bytes attr)]))   ; 普通格：attr 就是 face（符号 | #f）
