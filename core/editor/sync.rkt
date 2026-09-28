#lang racket

(require "state.rkt" "write.rkt" "../text/document.rkt" "../view/base/viewport.rkt")

;;; editor/sync.rkt —— 视口同步
;;;
;;; 两种同步关系（**都只同步视口，绝不动选区**）：
;;;     sync='follow   同 document 的视图跟随「发起视图」的视口
;;;     link=k         所有 link 相等的视图互相跟随（可跨 document）
;;;
;;; 「发起视图」= 当前改变视口的那个视图，由调用方把它的 vid 传给
;;; editor-sync-viewports。同步的是**锚点**（左上角 行 ⊕ 显示列），各跟随者按自己的
;;; mode / 尺寸落位。列的处理分两种：
;;;     同文档   精确取/放锚点（同一文本，列语义一致）
;;;     跨文档   按两侧锚行显示宽**比例**缩放列（文本不同，列不可直接搬）
;;;
;;; 列统一用「显示列」一种表示；比例只发生在跨文档那一步（见 view/base/viewport.rkt）。

(provide
 ;; 把同步组（sync='follow / link 相同）的视口对齐到 vid
 editor-sync-viewports)

;; 把 ed 里与 vid 同步的视图视口对齐到 vid 的视口。
(define (editor-sync-viewports ed vid)
  (define leader (editor-view-ref ed vid))
  (define t-leader (document-text (editor-view-document ed vid)))
  (define link (view-link leader))
  (define-values (line dc) (viewport-anchor t-leader (view-viewport leader)))
  (define (follows? x)
    (and (not (= vid (view-id x)))
         (or (and link (eq? link (view-link x)))                      ; 跨文档 link 组
             (and (= (view-did leader) (view-did x))                  ; 同文档 follow
                  (eq? 'follow (view-sync x))))))
  (for/fold ([ed* ed]) ([x (in-list (editor-views ed))] #:when (follows? x))
    (define t (document-text (editor-view-document ed* (view-id x))))
    (define vp* (if (= (view-did leader) (view-did x))
                    (viewport-set-anchor t (view-viewport x) line dc)
                    (viewport-mirror t-leader (view-viewport leader) t (view-viewport x))))
    (editor-set-view ed* (struct-copy view x [viewport vp*]))))
