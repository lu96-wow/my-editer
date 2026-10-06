#lang racket

;;; lab-rebuild/builtin/complete.rkt —— 补全菜单（layer + deco 浮层）。
;;;
;;; layer 'complete：fallthrough（打字仍落 base）+ pop never（显式 accept/cancel）。
;;; deco 'complete：每帧纯函数产菜单 pane（锚在光标）。
;;; 候选来自 lang（基础命名空间 + 本地定义）；查文档的异步接缝留待 docs 一起。

(require "../kernel/editor-api.rkt"
         "../kernel/effect.rkt"
         "../kernel/layer.rkt"
         "../kernel/session.rkt"
         "../kernel/runtime.rkt"
         "../kernel/registry.rkt"
         "../kernel/hooks.rkt"
         "../kernel/table.rkt"
         "../kernel/binding.rkt"
         "../kernel/overlay.rkt"
         "lang/ident.rkt" "lang/source.rkt" "lang/complete.rkt")

(provide register-complete! (struct-out cs))

(struct cs (cands idx start vid pool) #:transparent)

(define complete-keys
  (kbd (key 'up)     '(complete-move -1)
       (key 'down)   '(complete-move 1)
       (key 'tab)    'complete-accept
       (key 'enter)  'complete-accept
       (key 'escape) 'complete-cancel))

(define complete-layer
  (make-layer 'complete
              #:tables (λ (ctx inst) (list complete-keys))
              #:capture 'fallthrough
              #:pop 'never))

;;; ================= 命令 =================

(define (cmd-complete ctx ev)
  (define s (ctx-session ctx))
  (define vid (session-focus-vid s))
  (cond
    [(not vid) '()]
    [else
     (define ed (session-editor s))
     (define text (editor-view-string ed vid))
     (define p (editor-view-point ed vid))
     (define prefix (prefix-at text (point-line p) (point-column p)))
     (cond
       [(zero? (string-length prefix)) '()]
       [else
        (define pool (completion-pool #:modules '() #:locals (source-definitions text)))
        (define cands (filter-pool pool prefix))
        (if (pair? cands)
            (list (e-input-push 'complete
                                (cs cands 0
                                    (point (point-line p) (- (point-column p) (string-length prefix)))
                                    vid pool)))
            '())])]))

(define (cmd-complete-move ctx ev delta)
  (define inst (input-find (session-input (ctx-session ctx)) 'complete))
  (cond
    [(not inst) '()]
    [else
     (define st (layer-inst-state inst))
     (define n (length (cs-cands st)))
     (cond [(zero? n) '()]
           [else (list (e-input-set 'complete (struct-copy cs st [idx (modulo (+ (cs-idx st) delta) n)])))])]))

(define (cmd-complete-accept ctx ev)
  (define s (ctx-session ctx))
  (define inst (input-find (session-input s) 'complete))
  (cond
    [(not inst) '()]
    [else
     (define st (layer-inst-state inst))
     (define ed (session-editor s))
     (define vid (cs-vid st))
     (define cand (list-ref (cs-cands st) (cs-idx st)))
     (define p (editor-view-point ed vid))
     (list (e-input-pop 'complete)
           (e-move vid (selections-one (selection (cs-start st) p)))
           (e-type vid cand #f))]))

(define (cmd-complete-cancel ctx ev) (list (e-input-pop 'complete)))

;;; ================= 钩子 =================

(define (complete-refine ctx _args)
  (define s (ctx-session ctx))
  (define inst (input-find (session-input s) 'complete))
  (cond
    [(not inst) '()]
    [else
     (define st (layer-inst-state inst))
     (define vid (session-focus-vid s))
     (define ed (session-editor s))
     (define text (editor-view-string ed vid))
     (define p (editor-view-point ed vid))
     (define prefix (prefix-at text (point-line p) (point-column p)))
     (cond
       [(zero? (string-length prefix)) (list (e-input-pop 'complete))]
       [else
        (define cands (filter-pool (cs-pool st) prefix))
        (if (pair? cands)
            (list (e-input-set 'complete
                               (cs cands 0
                                   (point (point-line p) (max 0 (- (point-column p) (string-length prefix))))
                                   vid (cs-pool st))))
            (list (e-input-pop 'complete)))])]))

(define (complete-cancel-hook ctx _args) (list (e-input-pop 'complete)))

;;; ================= 浮层 =================

(define (complete-panes ctx)
  (define s (ctx-session ctx))
  (define inst (input-find (session-input s) 'complete))
  (cond
    [(not inst) '()]
    [else
     (define st (layer-inst-state inst))
     (define vid (cs-vid st))
     (define ed (session-editor s))
     (define-values (arow acol) (anchor-screen-pos ctx vid (editor-view-point ed vid)))
     (cond
       [(not arow) '()]
       [else
        (define cands (cs-cands st))
        (define idx (cs-idx st))
        (define n (length cands))
        (define mrows (min 10 n))
        (define start (max 0 (min (- idx (quotient mrows 2)) (- n mrows))))
        (define shown (take (drop cands start) mrows))
        (define cw (+ 2 (for/fold ([mx 0]) ([x (in-list shown)]) (max mx (string-length x)))))
        (define content
          (for/list ([i (in-range mrows)])
            (define x (list-ref shown i))
            (cons (string-append " " x) (if (= (+ start i) idx) (cons 'cursor 'state) 'state))))
        (define h (+ mrows 2))
        (define top (if (<= h (- (session-height s) (add1 arow))) (add1 arow) (max 0 (- arow h))))
        (define left (max 0 (min acol (max 0 (- (session-width s) (+ cw 2))))))
        (list (frame-pane 'complete top left cw content 10))])]))

;;; ================= 注册 =================

(define (register-complete! r)
  (for/fold ([r r])
            ([c (in-list
                 (list (contrib 'deco 'complete 0 (deco 'complete complete-panes))
                       (contrib 'layer-spec 'complete 0 complete-layer)
                       (contrib 'binding 'complete 0 (keybinding 'edit (key 'n 'ctrl) 'complete))
                       (contrib 'command 'complete 0 cmd-complete)
                       (contrib 'command 'complete-move 0 cmd-complete-move)
                       (contrib 'command 'complete-accept 0 cmd-complete-accept)
                       (contrib 'command 'complete-cancel 0 cmd-complete-cancel)
                       (contrib 'hook 'complete-refine 0 (make-hook 'after-insert complete-refine))
                       (contrib 'hook 'complete-cancel-nav 0 (make-hook 'after-nav complete-cancel-hook))
                       (contrib 'hook 'complete-cancel-focus 0 (make-hook 'focus-changed complete-cancel-hook))))])
    (reg-add r c)))
