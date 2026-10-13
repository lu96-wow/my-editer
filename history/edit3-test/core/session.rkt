#lang racket

;;; edit3-test/session.rkt —— 会话操作层（打开/保存/分裂/关闭/脏判定/区域/路径）
;;;
;;; 这些原语从 step 抽到 core/session.rkt，step 与插件共用。这里直接调 session 函数
;;; （不经路由），验证领域语义仍然正确、且不依赖 step 的路由。

(require rackunit racket/file
         "../../edit3/core/state.rkt"
         "../../edit3/core/effect.rkt"
         "../../edit3/core/layout.rkt"
         "../../edit3/core/window.rkt"
         "../../edit3/core/adapter.rkt"
         "../../edit3/core/panels.rkt"
         "../../edit3/core/session.rkt"
         "../../edit3/core/step.rkt")       ; boot（装配）仍在 step

(define (tile-wids st) (node-wids (tiling-root (state-tiling st))))

;; boot：3 个 tile（侧栏 + 编辑 + 状态栏），焦点空编辑窗 wid 0。
(define st0 (boot 80 24))
(check-equal? (length (tile-wids st0)) 3)
(check-false (focused-did st0))

;; ---- 打开文件（纯 session 原语，不经路由） ----
(define tmpdir (make-temporary-file "ed3sess~a" 'directory))
(define fpath (build-path tmpdir "a.txt"))
(display-to-file "hello\nworld\n" fpath #:exists 'truncate)

(define-values (st1 effs1) (open-file* st0 fpath))
(check-equal? effs1 '())
(define did1 (focused-did st1))
(check-true (and did1 #t))
(check-equal? (doc-meta-path (hash-ref (state-docs st1) did1)) (simplify-path (path->complete-path fpath)))
(check-equal? (view-string (state-ed st1) (focused-vid st1)) "hello\nworld\n")
(check-false (doc-dirty? st1 did1))                 ; 刚读入 = 干净

;; ---- 编辑 → 脏判定 ----
(define-values (st2 ign2) (insert-text st1 "Z"))
(check-true (doc-dirty? st2 did1))
(define-values (st3 effs3) (save-focused st2))
(define save-eff (for/first ([e (in-list effs3)] #:when (save-file? e)) e))
(check-true (save-file? save-eff))
(check-false (doc-dirty? st3 did1))                 ; 保存后 = 干净（引擎句柄已更新）
(check-equal? (save-file-text save-eff) "Zhello\nworld\n")

;; ---- 分裂 / 关闭窗口（平铺手术） ----
(define st4 (split-focused st3 'h #f))
(check-equal? (length (tile-wids st4)) 4)           ; 编辑区又裂出一个
(check-true (and (memv (state-focus st4) (tile-wids st4)) #t))
(check-false (focused-did st4))                     ; 新窗为空
(define st5 (close-window! st4 (state-focus st4)))
(check-equal? (length (tile-wids st5)) 3)
(check-equal? (state-focus st5) (state-focus st1))

;; ---- 区域成员切换（树 ↔ 缓冲区） ----
(check-equal? (region-active st5 'sidebar) "*tree*")
(define st6 (region-cycle! st5 'sidebar 1))
(check-equal? (region-active st6 'sidebar) "*buffers*")
(check-equal? (region-visible-vid st6 'sidebar) (panel-vid st6 "*buffers*"))
(check-true (region-visible? st6 'sidebar))
(define st7 (region-hide! st6 'sidebar))
(check-false (region-visible? st7 'sidebar))
(define st8 (region-show! st7 'sidebar))
(check-equal? (region-visible-vid st8 'sidebar) (panel-vid st8 "*buffers*"))  ; 记住上次成员

;; ---- 重新绑定路径（set-focused-path!） ----
(define fpath2 (build-path tmpdir "b.txt"))
(display-to-file "b\n" fpath2 #:exists 'truncate)
(define-values (st9 ign9) (open-file* st8 fpath2))
(define did2 (focused-did st9))
(define st10 (set-focused-path! st9 fpath2))        ; 幂等：同一路径
(check-equal? (doc-meta-path (hash-ref (state-docs st10) did2))
              (simplify-path (path->complete-path fpath2)))

;; ---- 焦点资源 / 关闭文档 ----
(define res (focus-resource st9))
(check-equal? (car res) did2)
(define st11 (close-doc! st9 did2))
(check-false (hash-has-key? (state-docs st11) did2))
(check-true (has-wid? st11 (state-focus st11)))     ; 焦点窗口仍在（变成空窗）

(delete-directory/files tmpdir)

(displayln "edit3/session.rkt: all tests passed")
