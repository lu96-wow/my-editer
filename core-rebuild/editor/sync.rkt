#lang racket

(require "state.rkt" "../text/document.rkt" "../view/base/viewport.rkt")

;;; editor/sync.rkt —— 视口同步（就地改 viewport box）
;;;
;;; 两种同步关系（都只同步视口，绝不动选区）：
;;;     sync='follow   同 document 的视图跟随「发起视图」的视口
;;;     link=k         所有 link 相等的视图互相跟随（可跨 document）
;;;
;;; 同步的是**锚点**（左上角 行 ⊕ 显示列）：同文档精确取/放；跨文档按显示宽比例缩放。

(provide editor-sync-viewports!)

(define (editor-sync-viewports! ed vid)
  (define leader (editor-view-ref ed vid))
  (define t-leader (document-text (editor-view-document ed vid)))
  (define link (view-link leader))
  (define-values (line dc) (viewport-anchor t-leader (view-viewport leader)))
  (define (follows? x)
    (and (not (= vid (view-id x)))
         (or (and link (eq? link (view-link x)))
             (and (= (view-did leader) (view-did x))
                  (eq? 'follow (view-sync x))))))
  (for ([x (in-list (editor-views ed))] #:when (follows? x))
    (define t (document-text (editor-view-document ed (view-id x))))
    (define vp* (if (= (view-did leader) (view-did x))
                    (viewport-set-anchor t (view-viewport x) line dc)
                    (viewport-mirror t-leader (view-viewport leader) t (view-viewport x))))
    (view-set-viewport! x vp*))
  (void))
