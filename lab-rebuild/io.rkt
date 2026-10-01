#lang racket

;;; ============================================================================
;;; io.rkt —— 中间层：后端无关的输入事件
;;; ============================================================================
;;;
;;; 后端（tui / gui / headless）与上层之间**唯一**的接口。事件按 racket/gui 的
;;; 模型定型，不按终端；后端在边界把自家事件翻译成这里的值。
;;;
;;;   modifiers  修饰键
;;;   key        物理键（char | 命名键）+ 修饰键     ← 命令走它，普通字符也算
;;;   text       已解码文本（IME / 粘贴，可多字符）
;;;   mouse      指针：press / release / move / drag
;;;   wheel      滚轮
;;;   resize     尺寸
;;;
;;; 坐标一律 0-based 屏幕格。命名键：
;;;   'up 'down 'left 'right 'home 'end 'pageup 'pagedown
;;;   'backspace 'delete 'enter 'tab 'escape
;;;
;;; 后端特化只发生在后端，本层不做任何归一/猜测。

(provide (struct-out modifiers) modifiers-none
         (struct-out key)
         (struct-out text)
         (struct-out mouse)
         (struct-out wheel)
         (struct-out resize)
         pointer-position
         plain-key?)

;;; ---------- 值 ----------

(struct modifiers (control alt shift meta) #:transparent)
(define modifiers-none (modifiers #f #f #f #f))

(struct key (name modifiers) #:transparent)
;; name : char（可打印键 / 带修饰的字母键）| symbol（命名键）

(struct text (s modifiers) #:transparent)

(struct mouse (kind button row col modifiers) #:transparent)
;; kind   : 'press | 'release | 'move | 'drag
;; button : 'left | 'middle | 'right（press/release/drag）；#f（无按键 move）

(struct wheel (direction row col modifiers) #:transparent)
;; direction : 'up | 'down

(struct resize (rows cols) #:transparent)

;;; ---------- 小工具 ----------

;; mouse / wheel 的屏幕坐标 → (values row col)
(define (pointer-position in)
  (cond [(mouse? in) (values (mouse-row in) (mouse-col in))]
        [(wheel? in) (values (wheel-row in) (wheel-col in))]
        [else (values #f #f)]))

;; 没有任何命令修饰键（Ctrl/Alt/Meta）的键。
(define (plain-key? k)
  (define m (key-modifiers k))
  (and (not (modifiers-control m)) (not (modifiers-alt m)) (not (modifiers-meta m))))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define ctrl (modifiers #t #f #f #f))
  (check-equal? (key-name (key #\v ctrl)) #\v)
  (check-true (modifiers-control (key-modifiers (key #\v ctrl))))
  (check-false (plain-key? (key #\v ctrl)))
  (check-true (plain-key? (key #\v modifiers-none)))
  (check-equal? (text-s (text "你好" modifiers-none)) "你好")
  (check-equal? (mouse-kind (mouse 'drag 'left 3 7 modifiers-none)) 'drag)
  (let-values ([(r c) (pointer-position (wheel 'down 2 5 modifiers-none))])
    (check-equal? (list r c) '(2 5)))
  (check-equal? (resize-rows (resize 20 80)) 20)

  (displayln "lab-rebuild/io.rkt: all tests passed"))
