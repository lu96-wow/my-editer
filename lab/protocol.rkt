#lang racket

;;; lab/protocol.rkt —— 后端 ↔ 编辑器之间的纯值协议
;;;
;;; 两个方向各一套值，除此之外两边不认识对方：
;;;   input   : 后端 → 编辑器（键盘 / 文本 / 鼠标 / 滚轮 / 尺寸）
;;;   effect  : 编辑器 → 后端（退出 / 读文件 / 写文件）
;;;
;;; 事件按 **racket/gui 的模型**定型，不按终端：后端在自己的边界把原始事件翻译成
;;; 这些值；编辑器只认这里，永不依赖任何具体后端。后端特化（如终端 Ctrl+字母给大写、
;;; 滚轮在 GTK 是 key-event）只发生在后端。
;;;
;;; 坐标一律 **0-based 屏幕格**（整屏左上角为原点）；像素后端在边界按字体度量换算。
;;;
;;; 命名键：'up 'down 'left 'right 'home 'end 'pageup 'pagedown
;;;         'backspace 'delete 'enter 'tab 'escape 'f1…'f12

(provide
 ;; ---------- input ----------
 (struct-out modifiers)
 modifiers-none
 (struct-out key)
 (struct-out text)
 (struct-out mouse)
 (struct-out wheel)
 (struct-out resize)
 pointer-position
 ;; ---------- effect ----------
 (struct-out quit)
 (struct-out io-load)
 (struct-out io-save))

;;; ================= input =================

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

;; mouse / wheel 的屏幕坐标（命中测试用）。→ (values row col)
(define (pointer-position in)
  (cond [(mouse? in) (values (mouse-row in) (mouse-col in))]
        [(wheel? in) (values (wheel-row in) (wheel-col in))]
        [else (values #f #f)]))

;;; ================= effect =================
;;; 命令层不直接做 io，只返回 effect 列表；由后端 / 组装根执行。

(struct quit () #:transparent)          ; 退出
(struct io-load (path) #:transparent)   ; 读文件到新文档
(struct io-save (path did) #:transparent)  ; 把某文档写回磁盘

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

  ;; effect 是纯值
  (check-equal? (io-save "a.txt" 3) (io-save "a.txt" 3))
  (check-true (quit? (quit)))

  (displayln "lab/protocol.rkt: all tests passed"))
