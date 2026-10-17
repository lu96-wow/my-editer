#lang racket

;;; bootstrap/filetree-panel.rkt —— 文件树面板（buffer 支撑）
;;;
;;; 安装 *filetree* document/view；每帧从磁盘生成行：
;;;   root 第一行 = 根目录路径
;;;   dir  缩进 2 空格/层，蓝色
;;;   file 已打开 = 绿色；否则灰色
;;;
;;; IO 读取在 sync / 命令里做，State 只存 view/root/expanded。

(provide install-filetree-panel! sync-filetree-panel! filetree-panel-view)
(provide (all-from-out "../projection/filetree.rkt"))

(require "../base/id.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/filetree.rkt"
         "../effects/engine.rkt"
         "../projection/filetree.rkt"
         "../../core/editor/ops.rkt"
         "../../core/editor/attributes.rkt"
         "../../core/editor/query.rkt"
         "../../core/editor/state.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/selection.rkt"
         "../../core/text/base/range.rkt")

(define (filetree-panel-view state)
  (filetree-view (state-filetree state)))

(define (install-filetree-panel! engine state region-id root)
  (define root* (filetree-normalize-path root))
  (define-values (did s1) (state-next-id state 'doc))
  (define-values (vid s2) (state-next-id s1 'view))
  (void (engine-create-doc! engine did "*filetree*" ""))
  (void (engine-create-view! engine vid did))
  (define ws (state-workspace s2))
  (define ws1 (workspace-add-doc ws did (make-doc-meta "*filetree*" #:mode 'filetree)))
  (define ws2 (workspace-add-view ws1 vid (view-meta did (hash))))
  (define reg (region region-id (list (view-member vid)) vid 'filetree))
  (define ws3 (workspace-add-region ws2 region-id reg))
  (state-filetree*
   (state-set-workspace s2 ws3)
   (λ (f)
     (define f1 (filetree-set-root f root*))
     (define f2 (if (filetree-expanded? f1 root*)
                    f1
                    (filetree-toggle-expand f1 root*)))
     (filetree-set-view f2 vid))))

(define (apply-faces! b lines)
  (for ([line (in-list lines)] [i (in-naturals)])
    (buffer-face-range! b
                        (range-of (point i 0)
                                  (point i (string-length (filetree-line-text line))))
                        (filetree-line-face line))))

(define (sync-filetree-panel! state engine)
  (define vid (filetree-panel-view state))
  (when vid
    (define v (engine-view-object engine vid))
    (when v
      (define b (view-buffer v))
      (define lines (filetree-lines state))
      (define text (string-join (map filetree-line-text lines) "\n"))
      (define old-line (view-point-line v))
      (define old-col (view-point-column v))
      (unless (string=? text (buffer-string b))
        (buffer-set-document! b text))
      (apply-faces! b lines)
      (define n (length lines))
      (define line (if (zero? n) 0 (min old-line (sub1 n))))
      (define lstr (if (zero? n) "" (filetree-line-text (list-ref lines line))))
      (define col (min old-col (string-length lstr)))
      (view-set-selections! v
                            (selections-one (caret (point line col)))
                            #:ensure? (equal? (state-focus state) vid))))
  (void))
