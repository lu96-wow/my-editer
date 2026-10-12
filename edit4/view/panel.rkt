#lang racket

;;; edit4/view/panel.rkt —— 面板：World -> 投影 的纯函数
;;;
;;; 一个面板就是一个函数：
;;;     panel : World -> (or (list vid text faces) #f)   ; 投影
;;; 面板的「名字」由闭包捕获（用来找到自己的面板文档），
;;; 不再有 panel-spec / panel-registry 的「贴标签 + 查表」。
;;;
;;; 组合 = map 一组面板函数；写引擎集中在 commit-panels!。
;;; 「一组面板」就是 (listof panel)，加面板 = 往列表里加一个闭包。
;;; 文件树的模型/IO 在 content/tree.rkt，具体面板在 view/{status,tree}.rkt。

(provide named-panel project-panels commit-panels! base-panels)

(require racket/list racket/match
         "../core/world.rkt"
         "../content/adapter.rkt"
         "../content/model.rkt"
         "status.rkt" "tree.rkt" "buffers.rkt" "log.rkt")

(define (panel-vid w name)
  (define c (world-content w))
  (and c (content-panel-vid c name)))

;; named-panel : name render -> (World -> projection | #f)
;; render : World × vid -> (values text faces)
(define (named-panel name render)
  (lambda (w)
    (define v (panel-vid w name))
    (and v (let-values ([(text faces) (render w v)]) (list v text faces)))))

;;; ---------- 投影（纯） ----------

(define (project-panels panels w)
  (filter values (map (lambda (p) (p w)) panels)))

;;; ---------- 写回（集中） ----------

(define (commit-panels! ed projections)
  (for ([p (in-list projections)])
    (match-define (list v text faces) p)
    (cond
      [(not text) (void)]
      [else
       (define old-line (view-line ed v))
       (define old-col (view-col ed v))
       (unless (equal? text (view-string ed v))
         (assign! ed v text)
         (define ls (string-split text "\n"))
         (define ln (if (null? ls) 0 (min old-line (sub1 (length ls)))))
         (define lc (if (null? ls) 0 (min old-col (string-length (list-ref ls ln)))))
         (set-point! ed v ln lc))
       (for ([f (in-list faces)]) (face-line! ed (view-did ed v) (car f) (cdr f)))])))

;;; ---------- 内置面板 ----------

(define base-panels
  (list (named-panel "*status*" status-content)
        (named-panel "*tree*" tree-content)
        (named-panel "*buffers*" buffers-content)
        (named-panel "*log*" log-content)))
