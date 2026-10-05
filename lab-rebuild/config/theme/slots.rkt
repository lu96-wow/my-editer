#lang racket

(require "theme.rkt")

;;; lab-rebuild/config/theme/slots.rkt —— 「可定义颜色」的槽位清单 + 主题构造
;;;
;;; 把**所有能定义颜色的地方**集中在这里声明，主题只负责往槽位里填颜色：
;;;
;;;   static-face-slots   静态 face（符号）——各 view-model / core 发出
;;;   palette-slots       动态调色板 kind（palette-color 用）
;;;   overlay-slots       overlay（selection；cursor 由后端按反色处理，不走主题）
;;;
;;; 主题 = 静态 face 表 + overlay 表 + default-face + 动态色板表。
;;; 色值一律是**固定值**（#f = 该维不设 / (r g b)）；不做任何运行时计算。
;;;
;;; `build-theme` 按槽位清单组装主题；`theme-missing-slots` 校验漏配（给测试用）。

(provide static-face-slots static-face-usage
         palette-slots palette-usage
         overlay-slots
         build-theme theme-missing-slots)

;; ---------- 静态 face：face 名 → 用在哪 ----------

(define static-face-usage
  '((line-number  "core 行号（core/view/project.rkt）")
    (tree-dir     "文件树 · 目录")
    (tree-file    "文件树 · 文件")
    (tree-link    "文件树 · 软链")
    (tree-hidden  "文件树 · 隐藏项")
    (tree-open    "文件树 · 已打开")
    (input        "底部输入行")
    (state        "底部状态行")
    (bar          "编辑区 / 分屏分隔线")
    (buf-current  "文档列表 · 当前 view")
    (buf-file     "文档列表 · 文件")
    (buf-untitled "文档列表 · 未命名")
    (buf-view     "文档列表 · view 行")))

(define static-face-slots (map car static-face-usage))

;; ---------- 动态色板：kind → 语义 ----------

(define palette-usage
  '((bracket "括号嵌套深度背景；按层取模")
    (word    "词着色前景；持久表 词→色号，取模")
    (keyword "关键字前景；按 keyword-list 位置取模")))

(define palette-slots (map car palette-usage))

;; ---------- overlay ----------

(define overlay-slots
  '(selection))

;;; ================= 组装 =================

;; 从**固定颜色表**构造主题（色值都是调用方给的现成表）。
;;   faces-fg / faces-bg : hash face -> (r g b)   （缺省 = #f，该维不设）
;;   default             : (list fg bg)
;;   overlays            : hash overlay -> (list fg bg)
;;   palettes            : hash kind -> vector of (list fg bg)
(define (build-theme #:faces-fg faces-fg #:faces-bg faces-bg
                     #:default default
                     #:overlays overlays
                     #:palettes palettes)
  (define faces
    (for/hash ([s (in-list static-face-slots)])
      (values s (list (hash-ref faces-fg s #f) (hash-ref faces-bg s #f)))))
  (theme faces overlays default palettes))

;; 主题漏配的槽位（face / palette / overlay）→ (list (list 'face x) …)；空 = 全覆盖。
(define (theme-missing-slots t)
  (append
   (for/list ([s (in-list static-face-slots)]
              #:unless (hash-has-key? (theme-faces t) s))
     (list 'face s))
   (for/list ([k (in-list palette-slots)]
              #:unless (hash-has-key? (theme-palettes t) k))
     (list 'palette k))
   (for/list ([o (in-list overlay-slots)]
              #:unless (hash-has-key? (theme-overlays t) o))
     (list 'overlay o))))
