#lang racket

;;; lab-rebuild/builtin/docs.rkt —— 文档浮窗（layer + deco + 异步）。
;;;
;;; C-p d → 查光标处标识符的 bluebox 文档（组合 doc-job 的 `view-modules` / `doc-await`）：
;;;   · view-modules 给出候选模块（严格 = #lang + 顶层 require；无则 racket/base）
;;;   · doc-request! 提交异步请求（place / sync）
;;;   · doc-await 登记文档句柄闸门；doc-job 统一 job-tick 轮询 → e-deliver
;;;   · on-result 命中则更新 docs 层状态
;;;   · deco 'docs 每帧画浮窗

(require "../kernel/editor-api.rkt"
         "../kernel/effect.rkt"
         "../kernel/layer.rkt"
         "../kernel/session.rkt"
         "../kernel/runtime.rkt"
         "../kernel/registry.rkt"
         "../kernel/table.rkt"
         "../kernel/binding.rkt"
         "../kernel/overlay.rkt"
         "../kernel/wrap.rkt"
         "lang/ident.rkt" "lang/docs.rkt" "lang/file-kind.rkt"
         "doc-scope.rkt"
         "doc-job.rkt")

(provide register-docs! (struct-out docs))

(struct docs (vid point lines offset width rows name) #:transparent)

(define docs-keys
  (kbd (key 'enter)    'docs-close
       (key 'escape)   'docs-close
       (key 'up)       '(docs-scroll -1)
       (key 'down)     '(docs-scroll 1)
       (key 'pageup)   '(docs-scroll -10)
       (key 'pagedown) '(docs-scroll 10)
       text-binding    'noop
       (key 'backspace) 'noop))

(define docs-layer
  (make-layer 'docs
              #:tables (λ (ctx inst) (list docs-keys))
              #:capture 'all
              #:pop 'never))

;;; ================= 命令 =================

(define (cmd-show-docs ctx ev)
  (define s (ctx-session ctx))
  (define vid (session-focus-vid s))
  (cond
    [(not vid) '()]
    [(not (doc-applies? ctx 'docs)) '()]      ; 文档查询也只对适用文档（当前 = Racket）
    [else
     (define ed (session-editor s))
     (define text (editor-view-string ed vid))
     (define p (editor-view-point ed vid))
     (define id (identifier-at text (point-line p) (point-column p)))
     (define mods (view-modules ctx vid))
     (define req-id (doc-request! ctx (or id "") mods))
     (define width (max 20 (min 88 (- (session-width s) 6))))
     (define rows (max 1 (min 20 (- (session-height s) 4))))
     (define placeholder (cond [(not id) "（光标处没有标识符）"] [else "查询文档…"]))
     (define st (docs vid p (list->vector (wrap-lines placeholder width)) 0 width rows (or id "")))
     (define (on-result c result)
       (define d (result->doc result))
       (define body (if d (doc->text d) (format "~a\n\n（未找到文档）" (or id ""))))
       (list (e-input-set 'docs (struct-copy docs st
                                             [lines (list->vector (wrap-lines body width))]
                                             [offset 0]))))
     (list (e-input-push 'docs st)
           (doc-await ctx vid req-id on-result))]))

(define (cmd-docs-close ctx ev) (list (e-input-pop 'docs)))

(define (cmd-docs-scroll ctx ev delta)
  (define inst (input-find (session-input (ctx-session ctx)) 'docs))
  (cond
    [(not inst) '()]
    [else
     (define st (layer-inst-state inst))
     (define n (vector-length (docs-lines st)))
     (define max-off (max 0 (- n (docs-rows st))))
     (list (e-input-set 'docs (struct-copy docs st
                                           [offset (max 0 (min max-off (+ (docs-offset st) delta)))])))]))

;;; ================= 浮层 =================

(define (docs-panes ctx)
  (define s (ctx-session ctx))
  (define inst (input-find (session-input s) 'docs))
  (cond
    [(not inst) '()]
    [else
     (define st (layer-inst-state inst))
     (define lines (docs-lines st))
     (define n (vector-length lines))
     (define cw (docs-width st))
     (define rows (max 1 (min (docs-rows st) n)))
     (define-values (arow acol) (anchor-screen-pos ctx (docs-vid st) (docs-point st)))
     (cond
       [(not arow) '()]
       [else
        (define h (+ rows 2))
        (define-values (top left)
          (anchor-placement arow acol cw h (session-width s) (session-height s)))
        (define off (max 0 (min (docs-offset st) (max 0 (- n rows)))))
        (define content (for/list ([i (in-range rows)]) (cons (vector-ref lines (+ off i)) 'state)))
        (list (frame-pane 'docs top left cw content 11))])]))

;;; ================= 钩子 / 注册 =================

(define (register-docs! r)
  (for/fold ([r (register-doc-job! r)])
            ([c (in-list
                 (list (contrib 'doc-scope 'docs 0 (doc-scope racket-buffer?))
                       (contrib 'deco 'docs 0 (deco 'docs docs-panes))
                       (contrib 'layer-spec 'docs 0 docs-layer)
                       (contrib 'binding 'docs 0 (keybinding 'focus (key 'd) 'show-docs))
                       (contrib 'command 'show-docs 0 cmd-show-docs)
                       (contrib 'command 'docs-close 0 cmd-docs-close)
                       (contrib 'command 'docs-scroll 0 cmd-docs-scroll)))])
    (reg-add r c)))
