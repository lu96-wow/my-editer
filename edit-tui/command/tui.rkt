#lang racket

;;; command/tui.rkt —— 命令层的 tui 适配：事件 → 键 → 键表
;;;
;;; 只做两件事：
;;;   1. `event->key`    把 racket-tui 的 key-event 解成键令牌（其余事件 → #f）；
;;;   2. `key-reader`    在有状态地读一个键序列：喂事件，命中叶子就执行过程，
;;;                      命中前缀就继续等，没命中就报告 —— 由宿主决定怎么办
;;;                      （丢给文本通道 / 忽略 / 提示）。
;;;
;;; 读键循环本身在宿主：宿主可能还要处理 resize / mouse / 重绘。
;;; 本模块只提供「喂一个事件，返回结果」这一能力。

(provide event->key
         (struct-out key-reader)
         make-key-reader
         key-reader-feed!
         key-reader-reset!
         key-reader-pending
         key-reader-pending-string
         (all-from-out "key.rkt" "keymap.rkt"))

(require tui "key.rkt" "keymap.rkt")

;;; ---------- 事件 → 键 ----------

(define (event->key ev)
  (and (key-event? ev)
       (let ([k (key-event-key ev)]
             [m (key-event-mods ev)])
         (apply key k
                (for/list ([s (in-list '(ctrl alt shift))]
                           [on? (in-list (list (mods-ctrl? m) (mods-alt? m) (mods-shift? m)))]
                           #:when on?)
                  s)))))

;;; ---------- 有状态读键 ----------

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

;; 喂一个事件 → 'handled | 'prefix | 'unbound | 'ignored
;;   handled : 命中叶子，过程已执行，回到根
;;   prefix  : 命中前缀，继续等下一个键
;;   unbound : 没命中，回到根（宿主可拿原事件当文本 / 提示）
;;   ignored : 不是按键事件（鼠标 / resize / null），键表不管
(define (key-reader-feed! kr ev)
  (define k (event->key ev))
  (cond
    [(not k) 'ignored]
    [else
     (define-values (status entry) (keymap-step (key-reader-current kr) k))
     (case status
       [(command) (entry)
                  (key-reader-reset! kr)
                  'handled]
       [(prefix) (set-key-reader-current! kr entry)
                 (set-key-reader-typed! kr (append (key-reader-typed kr) (list k)))
                 'prefix]
       [else (key-reader-reset! kr) 'unbound])]))

(module+ test
  (require rackunit)

  (define (ke k #:ctrl [c #f] #:alt [a #f] #:shift [s #f])
    (key-event k (mods c a s)))

  ;; 事件解码
  (check-equal? (event->key (ke 'left)) (key 'left))
  (check-equal? (event->key (ke #\A #:ctrl #t)) (key 'a 'ctrl))   ; ctrl 字符统一小写
  (check-equal? (event->key (ke #\x #:ctrl #t #:alt #t)) (key 'x 'ctrl 'alt))
  (check-equal? (event->key (ke #\space)) (key 'space))
  (check-false (event->key (null-event)))
  (check-false (event->key (resize-event 10 20)))

  ;; 读键：前缀 / 命中 / 未命中 / 非按键
  (define hits '())
  (define km (keys [(key 'x 'ctrl) (key 's 'ctrl) (λ () (set! hits (cons 'save hits))) ]
                   [(key 'q) (λ () (set! hits (cons 'q hits)))]))
  (define kr (make-key-reader km))
  (check-equal? (key-reader-feed! kr (ke #\x #:ctrl #t)) 'prefix)
  (check-equal? (key-reader-pending-string kr) "C-x")
  (check-equal? (key-reader-feed! kr (ke #\s #:ctrl #t)) 'handled)
  (check-equal? hits '(save))
  (check-false (key-reader-pending kr))
  (check-equal? (key-reader-feed! kr (ke #\z #:ctrl #t)) 'unbound)
  (check-equal? (key-reader-feed! kr (null-event)) 'ignored)
  (check-equal? (key-reader-feed! kr (ke #\q)) 'handled)
  (check-equal? hits '(q save))
  ;; 前缀中途打断：前缀状态清掉
  (void (key-reader-feed! kr (ke #\x #:ctrl #t)))
  (check-equal? (key-reader-feed! kr (ke #\z #:ctrl #t)) 'unbound)
  (check-false (key-reader-pending kr))

  (displayln "command/tui.rkt: ok"))
