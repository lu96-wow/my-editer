#lang racket

;;; lab/input.rkt —— 后端无关的输入事件（纯值）
;;;
;;; 这是后端（racket-tui / racket/gui / headless）与编辑器之间**唯一**的输入接口。
;;; 事件按 **racket/gui 的模型**定型，不按终端：后端在自己的边界把原始事件翻译成
;;; 这些值；编辑器只认这里，永不依赖任何具体后端。
;;;
;;;   modifiers  修饰键（control alt shift meta）
;;;   key        物理键（char 或命名键）+ 修饰键 —— 与已解码文本分离
;;;   text       已解码文本（IME / 粘贴 / 多字符）—— 消除「Ctrl+B 分屏 vs 输入 b」
;;;   mouse      指针：press / release / move / drag
;;;   wheel      滚轮（独立于 mouse，方向 up / down）
;;;   resize     尺寸变化
;;;
;;; 坐标一律 **0-based 屏幕格**（整屏左上角为原点）。像素后端（gui）在边界按字体
;;; 度量换算成格坐标。
;;;
;;; 后端映射（**后端特化只发生在后端**，本层不做任何归一/猜测）：
;;;
;;;   tui    key-event    → key（终端 Ctrl+字母给大写 → 后端自己归一成小写）
;;;          paste-event  → text
;;;          mouse move   → mouse 'drag（终端只在按住键拖动时上报 move）
;;;          mouse scroll → wheel（终端 scroll 带 up/down 按钮）
;;;   gui    on-char      → key（普通字符也是物理键；一次一个）
;;;          批量已解码文本 → text
;;;          motion 带按键  → mouse 'drag；不带 → mouse 'move
;;;          wheel          → wheel
;;;
;;; 命名键：'up 'down 'left 'right 'home 'end 'pageup 'pagedown
;;;         'backspace 'delete 'enter 'tab 'escape 'f1…'f12

(provide (struct-out modifiers)
         modifiers-none modifiers?
         (struct-out key)
         (struct-out text)
         (struct-out mouse)
         (struct-out wheel)
         (struct-out resize)
         pointer-position)

;;; ---------- 修饰键 ----------

(struct modifiers (control alt shift meta) #:transparent)
(define modifiers-none (modifiers #f #f #f #f))

;;; ---------- 键盘 ----------

;; name : char（可打印键 / 带修饰的字母键）| symbol（命名键，见文件头）
(struct key (name modifiers) #:transparent)

;; 已解码文本（IME / 粘贴 / 一次多个字符）。
(struct text (string modifiers) #:transparent)

;;; ---------- 指针 ----------

;; kind   : 'press | 'release | 'move | 'drag
;; button : 'left | 'middle | 'right（press/release/drag 携带）；#f（无按键的 move）
(struct mouse (kind button row col modifiers) #:transparent)

;; direction : 'up | 'down
(struct wheel (direction row col modifiers) #:transparent)

;;; ---------- 尺寸 ----------

(struct resize (rows cols) #:transparent)

;;; ---------- 坐标 ----------

;; mouse / wheel 的屏幕坐标（命中测试用）。→ (values row col)
(define (pointer-position in)
  (cond [(mouse? in) (values (mouse-row in) (mouse-col in))]
        [(wheel? in) (values (wheel-row in) (wheel-col in))]
        [else (values #f #f)]))

;;; ---------- 测试 ----------

(module+ test
  (require rackunit)

  (define ctrl-b (key #\b (modifiers #t #f #f #f)))
  (check-true (key? ctrl-b))
  (check-equal? (key-name ctrl-b) #\b)
  (check-true (modifiers-control (key-modifiers ctrl-b)))
  (check-false (modifiers-alt (key-modifiers ctrl-b)))

  ;; 物理键与文本分离：Ctrl+B 是 key，输入 b 是 text
  (check-true (key? (key 'enter modifiers-none)))
  (check-equal? (text-string (text "你好" modifiers-none)) "你好")

  ;; 指针：press / drag / move 靠 kind 区分（后端自己分类）
  (check-equal? (mouse-kind (mouse 'press 'left 3 7 modifiers-none)) 'press)
  (check-equal? (mouse-kind (mouse 'drag 'left 4 7 modifiers-none)) 'drag)
  (check-equal? (mouse-kind (mouse 'move #f 4 9 modifiers-none)) 'move)
  (let-values ([(r c) (pointer-position (mouse 'press 'left 3 7 modifiers-none))])
    (check-equal? (list r c) '(3 7)))
  (let-values ([(r c) (pointer-position (wheel 'down 2 5 modifiers-none))])
    (check-equal? (list r c) '(2 5)))

  (check-equal? (resize-rows (resize 20 80)) 20)

  ;; 纯值可比较（后端与编辑器之间只传值）
  (check-equal? (key 'enter modifiers-none) (key 'enter modifiers-none))

  (displayln "lab/input.rkt: all tests passed"))
