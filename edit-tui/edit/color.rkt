#lang racket

;;; edit-tui-rebuild/edit/color.rkt —— 编辑器着色同步（显式派生阶段）
;;;
;;; 职责：
;;;   1. 按 resource / doc 维护 lang/racket 的 color-state 缓存；
;;;   2. 消费 app-state 里的 pending-doc-changes，做增量 color-edit；
;;;   3. 把 syntax / word-color / bracket-depth role 组合成逐字符 face，写进 view。
;;;
;;; 缓存放在 app-state.store 的 'edit/color 键下；cache 本身是纯值。
;;; 这里不消费 / 清空 pending-doc-changes：其他派生阶段（如 completion）也要看。
;;; 真正的消费 / 清理由 run-loop 或 demo 的显式阶段决定。

(require (except-in racket/list range)
         racket/string
         "../core/skeleton.rkt"
         "../app/state.rkt"
         "../lang/racket/api.rkt")

(provide sync-editor-colors!
         editor-color-cache-key)

(define editor-color-cache-key 'edit/color)

;; version : engine 的 opaque document version
;; state   : lang/racket color-state
;; faces   : (listof (vectorof (or/c #f face?)))
(struct color-entry (version state faces) #:transparent)

(define (text-lines text)
  (string-split text "\n" #:trim? #f))

(define (racket-doc? path text)
  (if path
      (racket-file? path)
      (racket-text? text)))

(define (bracket-role? role)
  (and role
       (string-prefix? (symbol->string role) "bracket-depth-")))

;; role -> face。括号 role 是背景，其余 role 是前景 + 主题里自带的 attrs。
(define (role-face role)
  (if (bracket-role? role)
      (face #f role '())
      (face role #f '())))

;; 按 edit4 的层序：括号底色 -> 同词前景 -> 语法前景。
;; compose-face 是逐分量覆盖，所以语法只拿 fg，不冲掉括号 bg。
(define (combine-line syntax word bracket)
  (define n (vector-length syntax))
  (define out (make-vector n #f))
  (for ([i (in-range n)])
    (define f #f)
    (define br (and bracket
                    (< i (vector-length bracket))
                    (vector-ref bracket i)))
    (when br (set! f (compose-face f (role-face br))))
    (define wr (and word
                    (< i (vector-length word))
                    (vector-ref word i)))
    (when wr (set! f (compose-face f (role-face wr))))
    (define sr (and syntax
                    (< i (vector-length syntax))
                    (vector-ref syntax i)))
    (when sr (set! f (compose-face f (role-face sr))))
    (vector-set! out i f))
  out)

(define (color->faces cs)
  (for/list ([syntax (in-list (color-syntax-roles cs))]
             [word (in-list (color-word-roles cs))]
             [bracket (in-list (color-bracket-roles cs))])
    (combine-line syntax word bracket)))

;; core change -> lang 的行级编辑描述。
(define (changes->line-edits changes)
  (for/list ([ch (in-list changes)])
    (define b (change-before ch))
    (define a (change-after ch))
    (line-edit (point-line (range-start b))
               (point-line (range-end b))
               (point-line (range-start a))
               (point-line (range-end a)))))

(define (changes-for-doc pending did)
  (for/list ([dc (in-list pending)]
             #:when (equal? (doc-change-doc-id dc) did))
    dc))

(define (entry-for old version text doc-changes)
  (cond
    ;; 文本版本没变：直接复用上一帧。
    [(and old (equal? (color-entry-version old) version)) old]

    ;; 只有一个 change 且正好到当前版本：增量重扫脏行。
    [(and old
          (= (length doc-changes) 1)
          (equal? (doc-change-version (car doc-changes)) version))
     (define cs (color-edit (color-entry-state old)
                            text
                            (changes->line-edits
                             (doc-change-changes (car doc-changes)))))
     (color-entry version cs (color->faces cs))]

    ;; 首次打开 / 一次事件里多次编辑 / undo-redo（没有 change）：全量重建。
    [else
     (define cs (color-open text))
     (color-entry version cs (color->faces cs))]))

;; 对当前打开的所有 resource 做颜色同步。
;; 返回新 state（只改 store 里的颜色缓存）；engine 写 face 是派生副作用。
(define (sync-editor-colors! state engine)
  (define store (app-state-resources state))
  (define pending (app-state-pending-doc-changes state))
  (define old-colors
    (hash-ref (app-state-store state) editor-color-cache-key (hash)))

  (define new-colors
    (for/fold ([colors (hash)]) ([r (in-list (resource-list store))])
      (define did (resource-doc-id r))
      (define path (resource-path store (resource-id r)))
      (define text (and did (engine-doc-text engine did)))
      (cond
        [(not (and did text)) colors]
        [else
         (define version (engine-doc-version engine did))
         (define views (resource-views r))
         (cond
           [(racket-doc? path text)
            (define entry
              (entry-for (hash-ref old-colors did #f)
                         version
                         text
                         (changes-for-doc pending did)))
            (for ([vid (in-list views)])
              (engine-set-view-faces! engine vid
                                      (color-entry-faces entry)
                                      #:key (list did version 'racket)))
            (hash-set colors did entry)]
           [else
            ;; 非 Racket 文档也要清掉可能从 save-as 前留下的 face。
            (for ([vid (in-list views)])
              (engine-set-view-faces! engine vid
                                      '()
                                      #:key (list did version 'none)))
            colors])])))

  (struct-copy app-state state
               [store (hash-set (app-state-store state)
                                editor-color-cache-key
                                new-colors)]))
