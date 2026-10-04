#lang racket

(require tui)

;;; lab/base/input.rkt —— 输入协议（骨架）
;;;
;;; 事件直接用 **racket-tui 的规范化事件**（`key / paste / mouse / resize / null / other`
;;; + `mods`），我们不再自造事件类型；本文件只多做一件事：
;;;
;;;   event->binding : racket-tui 事件 → 命令表用的**绑定键**（匿名列表）
;;;
;;; 绑定键的形状（匿名 list，剥掉每次会变的量：坐标 / 粘贴内容）：
;;;   (list 'key   键 规范mods)    键 = symbol（字符键归一为小写 symbol，空格 = 'space）
;;;   (list 'mouse 动作 按钮 规范mods)
;;;   'text                        无 ctrl/alt 的字符键（可打印 / 空格）
;;;   'paste                       粘贴
;;;   'resize
;;;   #f                           null / 未识别（不参与查表）
;;;
;;; 边界约定：
;;;   - 字符键无 ctrl/alt → 'text（含空格）；带 ctrl/alt → (key 小写symbol mods)
;;;   - racket-tui 已把 tab / enter / backspace / escape / 方向键等归一为 symbol。
;;;   - 修饰键用 symbol 列表 (ctrl alt shift) 固定顺序，便于比较 / 建表。

(provide ;; 事件：直接重导出 racket-tui 的
         (struct-out mods) no-mods no-mods? ->mods mods->list
         (struct-out key-event) (struct-out paste-event)
         (struct-out mouse-event) (struct-out resize-event)
         (struct-out null-event) (struct-out other-event)
         event?
         ;; 绑定键
         key mouse text-binding paste-binding resize-binding
         normalize-mods
         ;; 鼠标坐标：racket-tui 是 1-based → 统一转成 0-based 屏幕格
         mouse-col mouse-row
         event->binding)

;;; ================= 绑定键 =================

(define mod-order '(ctrl alt shift))

(define (normalize-mods mods)
  (for/list ([m (in-list mod-order)] #:when (memq m mods)) m))

;; racket-tui mods 结构体 → 规范 symbol 列表。
(define (mods->symbols m)
  (for/list ([sym (in-list mod-order)] [on? (in-list (mods->list m))] #:when on?) sym))

;; 字符键 → symbol（小写；空格单独命名）。
(define (char->key-symbol c)
  (if (char=? c #\space) 'space (string->symbol (string-downcase (string c)))))

;; 建绑定键（也用于表 key）。
(define (key k . mods) (list 'key k (normalize-mods mods)))
(define (mouse action [button #f] [mods '()])
  (list 'mouse action button (normalize-mods mods)))
(define text-binding 'text)
(define paste-binding 'paste)
(define resize-binding 'resize)

;;; ================= 鼠标坐标 =================
;;; racket-tui 的 mouse-event x/y 是 1-based（终端列/行）。lab 内部一律 0-based 屏幕格，
;;; 所以消费端用 mouse-col / mouse-row，不要再直接用 mouse-event-x/y。
(define (mouse-col ev) (max 0 (sub1 (mouse-event-x ev))))
(define (mouse-row ev) (max 0 (sub1 (mouse-event-y ev))))

;;; ================= event → binding =================

(define (event->binding e)
  (cond
    [(key-event? e)
     (define k (key-event-key e))
     (define m (key-event-mods e))
     (cond
       ;; 无 ctrl/alt 的字符键 = 文本输入（含空格）
       [(and (char? k) (not (mods-ctrl? m)) (not (mods-alt? m))) text-binding]
       [else (list 'key (if (char? k) (char->key-symbol k) k) (mods->symbols m))])]
    [(paste-event? e) paste-binding]
    [(mouse-event? e)
     (list 'mouse (mouse-event-action e) (mouse-event-button e)
           (mods->symbols (mouse-event-mods e)))]
    [(resize-event? e) resize-binding]
    [(null-event? e) #f]
    [(other-event? e) #f]
    [else (error 'event->binding "不是 racket-tui 事件: ~a" e)]))
