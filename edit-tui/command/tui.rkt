#lang racket

;;; command/tui.rkt —— 命令层的 tui 适配：事件 → token → 键表
;;;
;;;   1. `event->key`    key-event    → 键令牌（其余 → #f）
;;;      `event->mouse`  mouse-event  → 鼠标令牌（其余 → #f）
;;;      `mouse-position` mouse-event → 0-based 屏幕 (row, col)
;;;   2. `key-reader`    有状态地读一个**键序列**：喂事件，命中叶子就**返回**过程，
;;;                      命中前缀就继续等，没命中就报告 —— 由宿主决定怎么办。
;;;
;;; 命令层**只路由、不调用**：命中叶子时返回 proc，宿主自己 `(proc ctx)`。
;;; 于是鼠标/键盘统一，handler 能拿位置；也支持数据驱动 world（proc 拿得到 world）。
;;; 鼠标无序列：直接 `(keymap-step mousemap (event->mouse ev))`。
;;;
;;; 读键循环本身在宿主：命中/位置/上下文表 / 拖拽状态都在宿主。

(provide event->key event->mouse mouse-position
         (struct-out key-reader)
         make-key-reader
         key-reader-feed!
         key-reader-reset!
         key-reader-pending
         key-reader-pending-string
         (all-from-out "key.rkt" "mouse.rkt" "keymap.rkt"))

(require tui "key.rkt" "mouse.rkt" "keymap.rkt")

(define mod-order '(ctrl alt shift))

(define (mods->symbols m)
  (for/list ([s (in-list mod-order)]
             [on? (in-list (list (mods-ctrl? m) (mods-alt? m) (mods-shift? m)))]
             #:when on?)
    s))

;;; ---------- 事件 → token ----------

(define (event->key ev)
  (and (key-event? ev)
       (apply key (key-event-key ev) (mods->symbols (key-event-mods ev)))))

(define (event->mouse ev)
  (and (mouse-event? ev)
       (apply mouse (mouse-event-action ev) (mouse-event-button ev)
              (mods->symbols (mouse-event-mods ev)))))

;; mouse-event 的 (x, y) 是 1-based；core 屏幕坐标是 0-based (row, col)。
;; 返回 (values row col)。
(define (mouse-position ev)
  (values (max 0 (sub1 (mouse-event-y ev)))
          (max 0 (sub1 (mouse-event-x ev)))))

;;; ---------- 有状态读键（键序列） ----------

(struct key-reader (root current typed) #:transparent #:mutable)
;; root    : keymap    本轮从哪张表起步（通常是合并后的活动表）
;; current : keymap    前缀走到哪了
;; typed   : (listof key?)  已按下的前缀键（正序），用于状态栏显示

(define (make-key-reader km) (key-reader km km '()))

(define (key-reader-reset! kr)
  (set-key-reader-current! kr (key-reader-root kr))
  (set-key-reader-typed! kr '()))

(define (key-reader-pending kr)
  (define t (key-reader-typed kr))
  (and (pair? t) t))

(define (key-reader-pending-string kr)
  (string-join (map key->string (key-reader-typed kr)) " "))

;; 喂一个事件 → (values status proc)
;;   'command : 命中叶子，proc = 命中的过程（宿主自己调用），回到根
;;   'prefix  : 命中前缀，继续等下一个键（proc = #f）
;;   'unbound : 没命中，回到根（宿主可拿原事件当文本 / 提示）
;;   'ignored : 不是按键事件（鼠标 / resize / null），键表不管
(define (key-reader-feed! kr ev)
  (define k (event->key ev))
  (cond
    [(not k) (values 'ignored #f)]
    [else
     (define-values (status entry) (keymap-step (key-reader-current kr) k))
     (case status
       [(command) (key-reader-reset! kr) (values 'command entry)]
       [(prefix) (set-key-reader-current! kr entry)
                 (set-key-reader-typed! kr (append (key-reader-typed kr) (list k)))
                 (values 'prefix #f)]
       [else (key-reader-reset! kr) (values 'unbound #f)])]))

(module+ test
  (require rackunit)

  (define (ke k #:ctrl [c #f] #:alt [a #f] #:shift [s #f])
    (key-event k (mods c a s)))
  (define (me action button #:ctrl [c #f] #:alt [a #f] #:shift [s #f])
    (mouse-event action button 5 3 (mods c a s)))

  ;; 事件解码
  (check-equal? (event->key (ke 'left)) (key 'left))
  (check-equal? (event->key (ke #\A #:ctrl #t)) (key 'a 'ctrl))   ; ctrl 字符统一小写
  (check-equal? (event->key (ke #\x #:ctrl #t #:alt #t)) (key 'x 'ctrl 'alt))
  (check-equal? (event->key (ke #\space)) (key 'space))
  (check-false (event->key (null-event)))
  (check-false (event->key (resize-event 10 20)))

  ;; 鼠标解码 + 位置（1-based → 0-based）
  (check-equal? (event->mouse (me 'press 'left)) (mouse 'press 'left))
  (check-equal? (event->mouse (me 'press 'left #:ctrl #t)) (mouse 'press 'left 'ctrl))
  (check-equal? (event->mouse (me 'scroll 'up #:shift #t)) (mouse 'scroll 'up 'shift))
  (check-equal? (event->mouse (me 'move #f)) (mouse 'move #f))
  (check-false (event->mouse (ke #\a)))
  (check-equal? (call-with-values (λ () (mouse-position (me 'press 'left))) list) '(2 4))

  ;; 读键：返回 proc，由调用方执行
  (define hits '())
  (define km (keys [(key 'x 'ctrl) (key 's 'ctrl) (λ () (set! hits (cons 'save hits)))]
                   [(key 'q) (λ () (set! hits (cons 'q hits)))]))
  (define kr (make-key-reader km))
  (check-equal? (call-with-values (λ () (key-reader-feed! kr (ke #\x #:ctrl #t))) list)
                (list 'prefix #f))
  (check-equal? (key-reader-pending-string kr) "C-x")
  (define-values (s1 p1) (key-reader-feed! kr (ke #\s #:ctrl #t)))
  (check-equal? s1 'command)
  (p1)
  (check-equal? hits '(save))
  (check-false (key-reader-pending kr))
  (check-equal? (call-with-values (λ () (key-reader-feed! kr (ke #\z #:ctrl #t))) list)
                (list 'unbound #f))
  (check-equal? (call-with-values (λ () (key-reader-feed! kr (null-event))) list)
                (list 'ignored #f))
  (define-values (s2 p2) (key-reader-feed! kr (ke #\q)))
  (check-equal? s2 'command)
  (p2)
  (check-equal? hits '(q save))
  ;; 前缀中途打断：前缀状态清掉
  (define-values (sx px) (key-reader-feed! kr (ke #\x #:ctrl #t)))
  (check-equal? sx 'prefix)
  (check-equal? (call-with-values (λ () (key-reader-feed! kr (ke #\z #:ctrl #t))) list)
                (list 'unbound #f))
  (check-false (key-reader-pending kr))

  ;; 鼠标表：单 token 直接命中（复用 keymap）
  (define mm (keys [(mouse 'press 'left) (λ () 'click)]
                   [(mouse 'press 'left 'ctrl) (λ () 'multi-cursor)]))
  (define-values (ms1 mp1) (keymap-step mm (event->mouse (me 'press 'left))))
  (check-equal? ms1 'command)
  (check-equal? (mp1) 'click)
  (define-values (ms2 mp2) (keymap-step mm (event->mouse (me 'press 'left #:ctrl #t))))
  (check-equal? ms2 'command)
  (check-equal? (mp2) 'multi-cursor)   ; 严格：Ctrl+左键走另一条
  (define-values (ms3 _) (keymap-step mm (event->mouse (me 'press 'right))))
  (check-equal? ms3 'unbound)

  (displayln "command/tui.rkt: ok"))
