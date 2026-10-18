#lang racket
(require "../edit-tui-rebuild/base/id.rkt"
         "../edit-tui-rebuild/base/effect.rkt"
         "../edit-tui-rebuild/base/transition.rkt"
         "../edit-tui-rebuild/model/state.rkt"
         "../edit-tui-rebuild/model/workspace.rkt"
         "../edit-tui-rebuild/model/face-layer.rkt"
         "../edit-tui-rebuild/effects/engine.rkt"
         "../edit-tui-rebuild/effects/interpreter.rkt"
         "../core/editor/ops.rkt"
         "../core/editor/query.rkt"
         "../core/text/base/point.rkt")

(define did (doc-id 1)) (define vid (view-id 1))
(define engine (make-engine))
(void (engine-create-doc! engine did "m" "(define (f)\n  (* 1 2))"))
(void (engine-create-view! engine vid did))
(engine-set-face-layers! engine '(depth-bg syntax-fg))
(define state (make-state))

;; T1：两层都已写好（深色层覆盖较长的一行）
(interpret-effect! engine state
  (set-face-layer-effect did 'depth-bg (list (list 1 2 1 8 (face-set-bg face-empty 'bg-depth-1)))))
(interpret-effect! engine state
  (set-face-layer-effect did 'syntax-fg (list (list 0 1 0 7 (face-set-fg face-empty 'fg-syntax-def)))))

;; 用户编辑：在开头插入一个换行 —— 第 1 行变成空行（旧 depth 的 fill 落在它上面）
(define b (engine-doc-buffer engine did))
(view-set-point! (engine-view-object engine vid) (point 1 0))
(buffer-edit! b (engine-view-object engine vid) (op-type "\n"))
(printf "text now: ~s\n" (buffer-string b))

;; T2：只回了一个插件的结果（另一个还是 T1 的层）→ 合成 → 写回
(interpret-effect! engine state
  (set-face-layer-effect did 'syntax-fg (list (list 1 1 1 3 (face-set-fg face-empty 'fg-syntax-def)))))
(printf "ok\n")
