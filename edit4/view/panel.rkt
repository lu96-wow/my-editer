#lang racket

;;; edit4/view/panel.rkt —— 面板：带名字的 World -> 投影 函数
;;;
;;; 面板 = (panel name render)：名字让 boot 能为它建文档（插件面板也要）。
;;;   render : World × vid -> (values text faces)
;;; 组合 = map 一组面板；写引擎集中在 commit-panels!。
;;; 具体面板在 view/{status,tree,buffers,log}.rkt。

(provide (struct-out panel) named-panel project-panels commit-panels! base-panels)

(require racket/list racket/match
         "../core/world.rkt"
         "../content/adapter.rkt"
         "../content/model.rkt"
         "status.rkt" "tree.rkt" "buffers.rkt" "log.rkt")

(define (panel-vid w name)
  (define c (world-content w))
  (and c (content-panel-vid c name)))

(struct panel (name render) #:transparent)
;; name   : string（面板文档名，如 "*status*"）
;; render : World × vid -> (values text faces)

(define (named-panel name render) (panel name render))

;;; ---------- 投影（纯） ----------

(define (project-panels panels w)
  (filter values
          (for/list ([p (in-list panels)])
            (define v (panel-vid w (panel-name p)))
            (and v (let-values ([(text faces) ((panel-render p) w v)])
                     (list v text faces))))))

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
;; *input* 不是投影面板（内容由 prompt.rkt 直接管理），由 boot 单独建文档。

(define base-panels
  (list (named-panel "*status*" status-content)
        (named-panel "*tree*" tree-content)
        (named-panel "*buffers*" buffers-content)
        (named-panel "*log*" log-content)))
