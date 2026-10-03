#lang racket

;;; lab/driver.rkt —— 组装根：把 input → dispatch → render → present → effects 串起来
;;;
;;;   app = session ⊕ 上一帧 ⊕ display ⊕ quit?
;;;
;;; 这是唯一同时认识 model / command / output / effect 的层（组装根），
;;; 但正因如此它很薄：只做「派发 → 呈现 → 执行 effect」。
;;;
;;; 后端只需：造一个 display、把原生事件译成 input、调 app-input。换后端不改这里。

(require racket/file racket/path
         "input.rkt"
         "effect.rkt"
         "output.rkt"
         "theme.rkt"
         "command/dispatch.rkt"
         "model/session.rkt"
         "model/document.rkt"
         "model/render.rkt"
         "model/tree.rkt")

(provide
 (struct-out app)
 app-open
 app-draw
 app-input
 execute-effects)

(struct app (session screen display quit?) #:transparent)

;; display 由后端提供；rows/cols 由后端查询后传入。两棵树在 app-open 时装配。
;; 默认不打开任何编辑器文档（空白）；需要时显式 #:text 开一个。
(define (app-open display rows cols [project #f] #:text [text #f] #:name [name "*scratch*"])
  (define s0 (trees-init (session-blank cols rows project)))
  (define s1 (if text
                 (let-values ([(s* _did _vid) (session-open-document s0 text name)]) s*)
                 s0))
  (app s1 #f display #f))

;; 渲染当前 session 并增量呈现；更新基线帧。
(define (app-draw a)
  (define new (session-render (app-session a)))
  (define drawn (present! (app-display a) (app-screen a) new attr->style))
  (struct-copy app a [screen drawn]))

;; 处理一个输入：派发 → 执行 effects → 刷新树 → 重绘。
(define (app-input a in)
  (define-values (s1 effs) (dispatch (app-session a) in))
  (define-values (s2 q?) (execute-effects s1 effs))
  (app-draw (struct-copy app a
              [session (trees-refresh s2)]
              [quit? (or (app-quit? a) q?)])))

;; 执行副作用（返回新 session + 是否退出）。io-load 可能新增文档（结构性）。
(define (execute-effects s effs)
  (for/fold ([s s] [q? #f] #:result (values s q?)) ([e (in-list effs)])
    (cond
      [(quit? e) (values s #t)]
      [(io-save? e)
       (display-to-file (document-text s (io-save-did e))
                        (io-save-path e) #:exists 'replace)
       (values s q?)]
      [(io-load? e)
       (define path (io-load-path e))          ; 字符串
       (define text (file->string path))
       (define name (path->string (file-name-from-path (string->path path))))
       (define-values (s* did _vid) (session-open-document s text name))
       (values (document-set-path s* did path) q?)]
      [else (values s q?)])))

;;; ---------- 测试（headless） ----------

(module+ test
  (require rackunit
           "io/headless.rkt")

  (define m0 (modifiers #f #f #f #f))
  (define mC (modifiers #t #f #f #f))

  (define-values (disp _spans) (make-headless-display 10 40))
  (define a0 (app-open disp 10 40 #f #:text "hello" #:name "d0"))
  (define a1 (app-draw a0))
  (check-false (app-quit? a1))

  (define s (app-session a1))
  (define did (for/first ([d (in-hash-keys (session-docs s))]
                          #:when (equal? (document-name s d) "d0"))
                d))

  ;; 输入 'X' → 文档变成 "Xhello"
  (define a2 (app-input a1 (key #\X m0)))
  (check-equal? (document-text (app-session a2) did) "Xhello")

  ;; C-q → quit
  (define a3 (app-input a2 (key #\q mC)))
  (check-true (app-quit? a3))

  (displayln "lab/driver.rkt: all tests passed"))
