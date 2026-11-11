#lang racket

;;; edit-tui-rebuild/plugins/racket-color/plugin.rkt —— Racket 基础语法着色
;;;
;;; 这是第一个真实使用 sync 阶段的派生插件：
;;;   · 每帧 sync：按 doc-id + version 判断是否需要重算；
;;;   · 版本没变时只把已有 face track 写给新 view（split 出来的 view 也能拿到颜色）；
;;;   · 版本变了才重新 color-open。
;;;
;;; 当前只把 syntax / word / bracket role 直接当 face symbol 用（优先级
;;; syntax > word > bracket），暂不做多 face 合成。等 core/face 搬进新树后再升级。

(require "../../editor/api.rkt"
         "../../../edit-tui/lang/racket/api.rkt")

(provide racket-color-plugin)

;; doc-id -> (cons version face-track)
(define empty-color-cache (hash))

(define (role-at roles i)
  (and roles
       (< i (vector-length roles))
       (vector-ref roles i)))

(define (line->faces syntax word bracket)
  (define n (vector-length syntax))
  (for/vector ([i (in-range n)])
    (or (role-at syntax i)
        (role-at word i)
        (role-at bracket i)
        #f)))

(define (color-state->face-track cs)
  (for/list ([syntax (in-vector (color-state-syntax-roles cs))]
             [word (in-vector (color-state-word-roles cs))]
             [bracket (in-vector (color-state-bracket-roles cs))])
    (line->faces syntax word bracket)))

(define (sync-colors ed state)
  (define engine (editor-engine ed))
  (define old-cache
    (or (editor-state-plugin-state state 'racket-color) empty-color-cache))
  (define (sync-doc cache did)
    (define text (engine-doc-text engine did))
    (define version (engine-doc-version engine did))
    (cond
      [(or (not text) (not version)) cache]
      [else
       (define vids (engine-view-ids-for-doc engine did))
       (define cached (hash-ref old-cache did #f))
       (define entry
         (cond
           [(and cached (equal? (car cached) version)) cached]
           [(racket-text? text)
            (define cs (color-open text))
            (cons version (color-state->face-track cs))]
           [else (cons version '())]))
       (define track (cdr entry))
       (define key (list did version 'racket-color))
       (for ([vid (in-list vids)])
         (engine-set-view-face-track! engine vid track
                                      #:base-version version
                                      #:key key))
       (hash-set cache did entry)]))
  (define new-cache
    (for/fold ([cache (hash)]) ([did (in-list (engine-doc-ids engine))])
      (sync-doc cache did)))
  (editor-state-set-plugin-state state 'racket-color new-cache))

(define racket-color-plugin
  (make-plugin
   #:id 'racket-color
   #:state empty-color-cache
   #:sync sync-colors))
