#lang racket

;;; projection/resources.rkt —— 资源列表的纯投影
;;;
;;; 行：
;;;   doc  line : 绿色（document）
;;;   view line : 蓝色（view），缩进在 document 下
;;;   view line : 缩进在 doc 下；显示 region / active / detached / placing
;;;
;;; 折叠集合在 state.resources.collapsed，选中项由 buffer 光标行决定。

(provide (struct-out resource-line)
         resource-lines
         resource-line-at
         resource-doc-line?
         resource-view-line?)

(require "../base/id.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/resources.rkt")

(struct resource-line (kind doc view text face) #:transparent)
;; kind : 'doc | 'view
;; doc  : doc-id
;; view : view-id | #f
;; text : string
;; face : symbol | #f

(define (listed-doc? dm)
  (not (memq (doc-meta-mode dm) '(status state input resources))))

(define (doc-label dm)
  (or (doc-meta-path dm) (doc-meta-name dm) "*untitled*"))

(define (doc-views ws did)
  (sort (for/list ([(vid vm) (in-hash (workspace-views ws))]
                   #:when (equal? (view-meta-doc vm) did))
          vid)
        string<? #:key id->string))

(define (resource-lines state)
  (define ws (state-workspace state))
  (define res (state-resources state))
  (define focus (state-focus state))
  (define docs
    (sort (for/list ([(did dm) (in-hash (workspace-docs ws))]
                     #:when (listed-doc? dm))
            (cons did dm))
          string<? #:key (λ (p) (doc-label (cdr p)))))
  (append*
   (for/list ([p (in-list docs)])
     (define did (car p))
     (define dm (cdr p))
     (define vids (doc-views ws did))
     (define collapsed? (resources-collapsed? res did))
     (define doc-line
       ; 文档行像文件夹：只显示名字；view 行缩进在下面。
       (resource-line 'doc did #f
                      (doc-label dm)
                      'resource-document))
     (define view-lines
       (if collapsed?
           '()
           (for/list ([vid (in-list vids)])
             (define reg (workspace-view-region ws vid))
             (define active? (and reg (equal? (region-active reg) vid)))
             (define focused? (equal? focus vid))
             (define pending? (equal? (resources-pending res) vid))
             (resource-line
              'view did vid
              (format "  ~a~a~a~a"
                      (id->string vid)
                      (if reg (format "  ~a" (id->string (region-key reg))) "  detached")
                      (if active? " *" "")
                      (cond [pending? "  [placing]"]
                            [focused? "  [focus]"]
                            [else ""]))
              (cond [pending? 'resource-pending]
                    [focused? 'resource-focus]
                    [else 'resource-view])))))
     (cons doc-line view-lines)))
  )

(define (resource-line-at state line)
  (define ls (resource-lines state))
  (and (exact-nonnegative-integer? line)
       (< line (length ls))
       (list-ref ls line)))

(define (resource-doc-line? l) (eq? (resource-line-kind l) 'doc))
(define (resource-view-line? l) (eq? (resource-line-kind l) 'view))
