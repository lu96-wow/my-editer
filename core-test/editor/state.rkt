#lang racket

;; 与 core/editor/state.rkt 对应的外部测试（**无焦点**：一律显式 vid/did）。
(require rackunit
         "../../core/editor/state.rkt"
         "../../core/text/document.rkt"
         "../../core/editor/history.rkt"
         "../../core/text/base/track.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/selection.rkt"
         "../../core/view/base/viewport.rkt")

(define ed (editor-open "abc\ndef" 40 10 "doc1"))

;; 构造
(check-equal? (length (editor-documents ed)) 1)
(check-equal? (document-entry-id (editor-document-entry ed 0)) 0)
(check-equal? (document-entry-name (editor-document-entry ed 0)) "doc1")

;; 视图 / 文档（vid 0）
(check-equal? (view-id (editor-view-ref ed 0)) 0)
(check-equal? (view-did (editor-view-ref ed 0)) 0)
(check-equal? (document->string (editor-view-document ed 0)) "abc\ndef")
(check-equal? (document-id-of ed (editor-view-document ed 0)) 0)
(check-equal? (view-id (first-view-of-document ed 0)) 0)

;; 视口 / 选区 初值
(check-true (viewport? (view-viewport (editor-view-ref ed 0))))
(check-equal? (selections-count (view-selections (editor-view-ref ed 0))) 1)

;; 加视图
(define-values (ed2 vid2) (editor-add-view ed 0 20 5))
(check-equal? vid2 1)   ; add-view 返回新 vid（与 add-document 返回 did 对称）
(check-equal? (length (editor-views ed2)) 2)
(check-equal? (view-id (second (editor-views ed2))) 1)
(check-equal? (view-did (second (editor-views ed2))) 0)

;; 一步建文档 + 视图 → (values editor did vid)
(define-values (dv1 dv-did dv-vid) (editor-add-document-view ed "status" 10 1 "sb" #:history? #f))
(check-equal? dv-did 1)
(check-equal? dv-vid 1)
(check-equal? (view-did (editor-view-ref dv1 dv-vid)) dv-did)
(check-equal? (document->string (editor-view-document dv1 dv-vid)) "status")
(check-equal? (viewport-width (view-viewport (editor-view-ref dv1 dv-vid))) 10)
(check-equal? (viewport-height (view-viewport (editor-view-ref dv1 dv-vid))) 1)
(check-false (history-enabled? (editor-document-history dv1 dv-did)))

;; 错误
(check-exn exn:fail? (lambda () (editor-document-entry ed 9)))
(check-exn exn:fail? (lambda () (editor-view-ref ed 9)))
(check-exn exn:fail? (lambda () (document-id-of ed (document-open "x"))))

;; 多文档：editor-add-document → (values editor did)
(define-values (ed-m did1) (editor-add-document ed "second" "doc2"))
(check-equal? did1 1)
(check-equal? (length (editor-documents ed-m)) 2)
(check-equal? (document-entry-id (editor-document-entry ed-m 1)) 1)
(check-equal? (document-entry-name (editor-document-entry ed-m 1)) "doc2")
(check-equal? (document->string (document-entry-document (editor-document-entry ed-m 1))) "second")
;; 给新文档加视图
(define-values (ed-m2 em2-vid) (editor-add-view ed-m 1 20 5))
(check-equal? (view-did (editor-view-ref ed-m2 1)) 1)
(check-equal? (document->string (editor-view-document ed-m2 1)) "second")
(check-equal? (document->string (editor-view-document ed-m2 0)) "abc\ndef")

;; ---------- 生命周期：改名 / 关视图 / 关文档（焦点由宿主自理，core 不管） ----------
(define ls0 (editor-open "abc\ndef" 20 5 "d0"))
(define-values (ls1 ls1-vid) (editor-add-view ls0 0 20 5))                 ; vid1
(define ls2 ls1)
(editor-document-set-name! ls2 0 "renamed")
(check-equal? (document-entry-name (editor-document-entry ls2 0)) "renamed")

;; ---------- did 版 history 开关（与 vid 版等价；无 view 的文档也能用） ----------
(define hs0 (editor-open "abc" 20 5 "h0"))
(editor-document-set-history-enabled! hs0 0 #f)
(check-false (history-enabled? (editor-document-history hs0 0)))
(editor-document-set-history-enabled! hs0 0 #t)
(check-true (history-enabled? (editor-document-history hs0 0)))
;; 0 个 view 的文档：没有 vid 可走，只能 did
(define-values (hs1 hs-did) (editor-add-document hs0 "no-view" "nv"))
(check-false (first-view-of-document hs1 hs-did))
(check-true (history-enabled? (editor-document-history hs1 hs-did)))
(editor-document-set-history-enabled! hs1 hs-did #f)
(check-false (history-enabled? (editor-document-history hs1 hs-did)))

(define ls3 (editor-close-view ls2 1))
(check-equal? (length (editor-views ls3)) 1)
(define ls4 (editor-close-view ls2 0))
(check-equal? (length (editor-views ls4)) 1)
(check-equal? (length (editor-views (editor-close-view ls4 1))) 0)

;; 关文档：连带它的视图一起去掉
(define-values (ls6 did-ls) (editor-add-document ls2 "second" "d1"))
(define-values (ls7 ls7-vid) (editor-add-view ls6 did-ls 20 5))              ; vid2
(define ls9 (editor-close-document ls7 did-ls))
(check-equal? (length (editor-documents ls9)) 1)
(check-equal? (length (editor-views ls9)) 2)             ; 只剩 doc0 的两个视图

;; ---------- 创建参数透传到 editor 层：分块行数 / 撤销栈深度 ----------
(check-equal? (track-max (document-text (editor-view-document ed 0))) default-chunk-lines)
(check-equal? (track-max (document-text (editor-view-document (editor-open "a\nb\nc" 20 5 "n" #:chunk-lines 2) 0))) 2)
(define-values (cb-ed cb-did) (editor-add-document ed "a\nb\nc" "n" #:chunk-lines 4 #:history-limit 7))
(check-equal? (track-max (document-text (document-entry-document (editor-document-entry cb-ed cb-did)))) 4)
(check-equal? (history-limit (editor-document-history cb-ed cb-did)) 7)
(check-equal? (history-limit (editor-document-history (editor-open "x" 20 5 #:history-limit 5) 0)) 5)

;; ---------- 视图初始 mode / 行号 ----------
(check-equal? (viewport-mode (view-viewport (editor-view-ref (editor-open "x" 20 5 #:mode 'wrap) 0))) 'wrap)
(check-true (viewport-line-numbers? (view-viewport (editor-view-ref (editor-open "x" 20 5 #:line-numbers? #t) 0))))
(define-values (mv-ed mv-vid) (editor-add-view ed 0 20 5 'free #f #:mode 'wrap #:line-numbers? #t))
(check-equal? (viewport-mode (view-viewport (editor-view-ref mv-ed 1))) 'wrap)
(check-true (viewport-line-numbers? (view-viewport (editor-view-ref mv-ed 1))))
;; 默认：clip + 关行号
(check-equal? (viewport-mode (view-viewport (editor-view-ref ed 0))) 'clip)
(check-false (viewport-line-numbers? (view-viewport (editor-view-ref ed 0))))

;; ---------- 入口多态：直接喂现成 document（带属性） ----------
(define pre-doc (document-highlight-fill (document-open "abcd\nef") 0 1 1 1 'kw))
(define pv-ed (editor-open pre-doc 20 5 "pre"))
(check-equal? (document->string (editor-view-document pv-ed 0)) "abcd\nef")
(check-equal? (document-highlight-row (editor-view-document pv-ed 0) 0) (vector #f 'kw 'kw 'kw))
(check-equal? (document-highlight-row (editor-view-document pv-ed 0) 1) (vector 'kw #f))
;; 同值 document 进 editor 后仍是该值（不经 string 重建）
(check-true (eq? (editor-view-document pv-ed 0) pre-doc))
;; editor-add-document 同样多态
(define-values (av-ed av-did) (editor-add-document ed pre-doc "pre2"))
(check-equal? (document-highlight-row (document-entry-document (editor-document-entry av-ed av-did)) 1)
              (vector 'kw #f))
(check-equal? (document->string (document-entry-document (editor-document-entry ed 0))) "abc\ndef")   ; 原 editor 不变

;; ---------- 空 editor（无文档 / 无视图） ----------
(define eb (editor-blank))
(check-equal? (length (editor-documents eb)) 0)
(check-equal? (length (editor-views eb)) 0)
(check-false (editor-clipboard eb))
;; 从空 editor 建第一个文档 + 视图，id 从 0 开始
(define-values (eb2 eb-did eb-vid) (editor-add-document-view eb "x" 10 5 "n"))
(check-equal? eb-did 0)
(check-equal? eb-vid 0)
(check-equal? (length (editor-documents eb2)) 1)
(check-equal? (document->string (editor-view-document eb2 0)) "x")

(displayln "editor/state.rkt: all tests passed")
