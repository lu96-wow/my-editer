#lang racket

;;; 由 edit-tui/command/tui.rkt 的测试外移而来（edit-tui 只留实现）。
(require rackunit
         tui
         "../../edit-tui/command/tui.rkt")

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
(define kt (make-keytable
           (keys [(key 'x 'ctrl) (key 's 'ctrl) (λ () (set! hits (cons 'save hits)))]
                 [(key 'q) (λ () (set! hits (cons 'q hits)))])))
(define kr (make-key-reader kt))
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

;; 运行时动态加表：读键器持有同一个 keytable，新表立刻生效
(void (keytable-merge! kt (keys [(key 'q 'ctrl) (λ () (set! hits (cons 'quit hits)))])))
(define-values (s4 p4) (key-reader-feed! kr (ke #\q #:ctrl #t)))
(check-equal? s4 'command)
(p4)
(check-equal? (car hits) 'quit)

;; 鼠标表：单 token 直接命中（复用 keytable + 单元素序列查找）
(define mm (make-keytable
            (keys [(mouse 'press 'left) (λ () 'click)]
                  [(mouse 'press 'left 'ctrl) (λ () 'multi-cursor)])))
(define-values (ms1 mp1) (keytable-lookup mm (list (event->mouse (me 'press 'left)))))
(check-equal? ms1 'command)
(check-equal? (mp1) 'click)
(define-values (ms2 mp2) (keytable-lookup mm (list (event->mouse (me 'press 'left #:ctrl #t)))))
(check-equal? ms2 'command)
(check-equal? (mp2) 'multi-cursor)   ; 严格：Ctrl+左键走另一条
(define-values (ms3 _) (keytable-lookup mm (list (event->mouse (me 'press 'right)))))
(check-equal? ms3 'unbound)

(displayln "edit-tui/command/tui.rkt: ok")
