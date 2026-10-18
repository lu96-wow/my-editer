#lang racket

;;; edit-tui-rebuild/test/face-layer.rkt —— face 分层：合成规则 + 引擎写回
;;;
;;; 覆盖：
;;;   1. 纯合成（model/face-layer.rkt）：逐分量合并、attrs 并集、层序无关（不同分量）、
;;;      同分量时后层覆盖、相邻同 face 合并；
;;;   2. 引擎分层：两层各写一次 set-face-layer-effect，core 的格子上两个分量都在；
;;;      再写同一层 → 只更新那一层，另一层不受影响；
;;;   3. 端到端：两个插件（前景 / 背景）同时启用，互不覆盖。

(require rackunit
         racket/async-channel
         "../base/id.rkt"
         "../base/transition.rkt"
         "../base/effect.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../model/face-layer.rkt"
         "../effects/engine.rkt"
         "../effects/interpreter.rkt"
         "../plugins/builtin.rkt"
         "../runtime/run.rkt"
         "../../edit-tui/base/face.rkt"
         "../../core/editor/query.rkt")

;;; ════════════════ 1. 纯合成 ════════════════

(define (fg name) (face-set-fg face-empty name))
(define (bg name) (face-set-bg face-empty name))
(define (cell-at fills line col)
  (for/first ([f (in-list fills)]
              #:when (and (= (list-ref f 0) line)
                          (<= (list-ref f 1) col)
                          (< col (list-ref f 3))))
    (list-ref f 4)))

(let ()
  (define layers (hash 'bg (list (list 0 0 0 10 (bg 'bg-a)))
                       'fg (list (list 0 3 0 6 (fg 'fg-x)))))
  (define composed (compose-layers '(bg fg) layers))
  ;; 只有背景
  (check-equal? (face-bg (cell-at composed 0 0)) 'bg-a)
  (check-false (face-fg (cell-at composed 0 0)))
  ;; 重叠区：两个分量都在
  (check-equal? (face-fg (cell-at composed 0 4)) 'fg-x)
  (check-equal? (face-bg (cell-at composed 0 4)) 'bg-a)
  ;; 层序换过来：不同分量，结果相同（谁写 fg 谁写 bg 互不影响）
  (check-equal? (compose-layers '(fg bg) layers) composed)

  ;; 同分量：后层覆盖
  (define both (hash 'a (list (list 0 0 0 5 (fg 'fg-1)))
                     'b (list (list 0 2 0 4 (fg 'fg-2)))))
  (check-equal? (face-fg (cell-at (compose-layers '(a b) both) 0 2)) 'fg-2)
  (check-equal? (face-fg (cell-at (compose-layers '(b a) both) 0 2)) 'fg-1)

  ;; attrs 并集
  (define attr-a (face-add-attr (fg 'fg) 'bold))
  (define attr-b (face-set-attrs face-empty '(italic)))
  (define composed-attrs
    (compose-layers '(a b) (hash 'a (list (list 0 0 0 1 attr-a))
                                 'b (list (list 0 0 0 1 attr-b)))))
  (check-equal? (face-fg (cell-at composed-attrs 0 0)) 'fg)
  (check-equal? (face-attrs (cell-at composed-attrs 0 0)) '(bold italic))

  ;; 没声明层序的层：排在后面（不丢），并按名字排序
  (define extra (hash 'a (list (list 0 0 0 1 (fg 'fg-a)))
                      'z (list (list 0 0 0 1 (fg 'fg-z)))))
  (check-equal? (face-fg (cell-at (compose-layers '(a) extra) 0 0)) 'fg-z)

  ;; 相邻同 face 合并成一段
  (check-equal? (length (compose-layers '(a) (hash 'a (list (list 0 0 0 3 (fg 'f))
                                                           (list 0 3 0 5 (fg 'f))))))
                1))

;;; ════════════════ 2. 引擎分层（core 端口上的最终 face） ════════════════

(define did (doc-id 1))
(define vid (view-id 1))
(define rid (region-id 1))

(define (make-engine+state)
  (define engine (make-engine))
  (void (engine-create-doc! engine did "m" "abcdefghij"))
  (void (engine-create-view! engine vid did))
  (define ws
    (let* ([ws (workspace-empty)]
           [ws (workspace-add-doc ws did (make-doc-meta "m" #:path "/tmp/m.rkt"))]
           [ws (workspace-add-view ws vid (view-meta did (hash)))]
           [ws (workspace-add-region ws rid (region rid (list (view-member vid)) vid 'editor))])
      (struct-copy workspace ws [layout (make-leaf rid)])))
  (values engine (make-state #:workspace ws)))

(let-values ([(engine s0) (make-engine+state)])
  (engine-set-face-layers! engine '(bg fg))
  (define (run e) (transition-state (interpret-effect! engine s0 e)))
  (define s1 (run (set-face-layer-effect did 'bg (list (list 0 0 0 10 (bg 'bg-a))))))
  (define s2 (run (set-face-layer-effect did 'fg (list (list 0 2 0 5 (fg 'fg-x))))))
  (void s1) (void s2)
  (define b (engine-doc-buffer engine did))
  (check-equal? (face-bg (buffer-face-at b 0 0)) 'bg-a)
  (check-false (face-fg (buffer-face-at b 0 0)))
  (check-equal? (face-fg (buffer-face-at b 0 3)) 'fg-x)
  (check-equal? (face-bg (buffer-face-at b 0 3)) 'bg-a)

  ;; 只更新背景层：前景层不受影响
  (run (set-face-layer-effect did 'bg (list (list 0 0 0 10 (bg 'bg-b)))))
  (check-equal? (face-bg (buffer-face-at b 0 3)) 'bg-b)
  (check-equal? (face-fg (buffer-face-at b 0 3)) 'fg-x)
  ;; 只更新前景层：背景层不受影响
  (run (set-face-layer-effect did 'fg (list (list 0 4 0 6 (fg 'fg-y)))))
  (check-equal? (face-bg (buffer-face-at b 0 4)) 'bg-b)
  (check-equal? (face-fg (buffer-face-at b 0 4)) 'fg-y)
  ;; 新前景层里没有的格 -> 那格前景回到 #f
  (check-false (face-fg (buffer-face-at b 0 1))))

;;; ════════════════ 3. 端到端：两个插件（前景 / 背景）互不覆盖 ════════════════

(require "../plugins/highlight/plugin.rkt"
         "../plugins/highlight/depth-plugin.rkt"
         "../env/environment.rkt"
         "../env/plugin.rkt"
         "../base/keymap.rkt"
         "../env/mode.rkt"
         "../env/defaults.rkt")

(let ()
  (define engine (make-engine))
  (void (engine-create-doc! engine did "m.rkt" "(define (square x) (* x x))"))
  (void (engine-create-view! engine vid did))
  (define ws0
    (let* ([ws (workspace-empty)]
           [ws (workspace-add-doc ws did (make-doc-meta "m.rkt" #:path "/tmp/m.rkt"))]
           [ws (workspace-add-view ws vid (view-meta did (hash)))]
           [ws (workspace-add-region ws rid (region rid (list (view-member vid)) vid 'editor))])
      (struct-copy workspace ws [layout (make-leaf rid)])))
  (define s0 (state-set-focus (make-state #:workspace ws0) vid))
  ;; 只装这两个插件（不装 default-plugins）+ 声明层序（先背景后前景）
  (define env
    (plugins-env
     (environment-merge default-environment
                        (make-environment #:modes (hash 'text (make-mode #:fallback 'insert))
                                          #:keymaps (hash 'global (keys))))
     (list (depth-bg-plugin) (highlight-plugin))))
  (check-equal? (environment-face-layers env) '(depth-bg syntax-fg))
  ;; startup! 会按 doc-meta 挂上两个 face-decor，open 整篇后写回两层。
  (startup! env engine s0)
  (define b (engine-doc-buffer engine did))
  (check-equal? (face-fg (buffer-face-at b 0 1)) 'fg-syntax-def)   ; 前景：define
  (check-equal? (face-bg (buffer-face-at b 0 1)) 'bg-depth-1)      ; 背景：深度 1
  ;; 括号没有前景，但有深度背景（两个插件互不覆盖）
  (check-false (face-fg (buffer-face-at b 0 0)))
  (check-equal? (face-bg (buffer-face-at b 0 0)) 'bg-depth-1))
