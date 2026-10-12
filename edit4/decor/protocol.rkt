#lang racket

;;; edit4/decor/protocol.rkt —— decor 协议（乙：每插件自写 open / change）
;;;
;;; 装饰 = 一对纯函数 + 自己的增量状态与**层**：
;;;   open   : path text -> (values state layer)                整篇初次扫描
;;;   change : state layer ctx -> (values state layer dirty)    一次编辑 / 一次光标推进
;;;   layer  : track，行 payload = (vectorof face) | #f         与文本行对齐
;;;   dirty  : dirty（全脏 | 行集合）                             本次要重写的行
;;;
;;; ctx 只给中性结构（文本轨 / changes / 光标点）；「什么算一个词」这类词法在 lex.rkt。
;;; open / change 都是纯函数，不碰引擎；状态与层的写回由 view/decor 的槽驱动负责。
;;;
;;; pure-decor：把旧的「整篇纯扫描」函数包成 open/change（整篇重扫，迁移期兜底）。

(provide (struct-out face-ctx) (struct-out decor) pure-decor)

(require racket/list
         racket/string
         "dirty.rkt"
         "../../core/text/base/change.rkt"
         "../../core/text/base/track.rkt"
         "../../core/text/base/line.rkt")

;; 增量编辑上下文（槽驱动构造）。
(struct face-ctx (old-text new-text changes dirty path cursor) #:transparent)
;; old-text / new-text : track                  编辑前 / 后文本轨
;; changes : (listof change)                    本次编辑（空 = 纯光标推进）
;; dirty   : dirty                              changes 直接波及的整行（新坐标）
;; path    : path | #f
;; cursor  : (cons line col) | #f               当前视图光标（不在本文档 → #f）

(struct decor (open change) #:transparent)

;; 把「整篇纯扫描」的旧式装饰包成 open/change。
;;   scan : path string cursor -> (listof (vectorof face))   不适用 → '()
;; open / change 都整篇重扫（dirty-all）；仅用于尚未迁移到增量的装饰。
(define (pure-decor scan)
  (decor
   (lambda (path text)
     (values #f (scan->layer scan path text #f)))
   (lambda (state layer ctx)
     (define changes (face-ctx-changes ctx))
     (define cursor (face-ctx-cursor ctx))
     (cond
       ;; 无编辑且光标未动 → 不重扫（帧间空转）
       [(and (null? changes) (equal? state cursor)) (values state layer (dirty-lines '()))]
       [else (values cursor
                     (scan->layer scan (face-ctx-path ctx) (face-ctx-new-text ctx) cursor)
                     (dirty-all))]))))

(define (scan->layer scan path text cursor)
  (define lines (track->list text))
  (define faces (scan path (lines->string lines) cursor))
  (track-of-list
   (for/list ([line (in-list lines)] [i (in-naturals)])
     (cond
       [(< i (length faces)) (fit-vec (list-ref faces i) (string-length line))]
       [else #f]))))

;; 旧扫描器按行返回的向量长度理论上与行一致；不一致时夹/补，保证与文本对齐。
(define (fit-vec vec len)
  (cond
    [(= (vector-length vec) len) vec]
    [else
     (define v (make-vector len #f))
     (for ([i (in-range (min len (vector-length vec)))]) (vector-set! v i (vector-ref vec i)))
     v]))
