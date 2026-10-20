#lang racket

;;; edit-tui-rebuild/filetree/panel.rkt —— 文件树面板同步
;;;
;;; 每帧：
;;;   resource paths -> opened 集合
;;;   dir-entries + expanded -> 行
;;;   rows / cursor 写回 app-state.store['filetree]
;;;   同时把文本 / face / 光标写进 core view

(require "../app/state.rkt"
         "../resource/api.rkt"
         "../runtime/engine.rkt"
         "model.rkt"
         "lines.rkt"
         "scan.rkt")

(provide sync-filetree!)

(define (filetree-state state)
  (hash-ref (app-state-store state) 'filetree #f))

(define (set-filetree-state state f)
  (struct-copy app-state state
               [store (hash-set (app-state-store state) 'filetree f)]))

(define (opened-paths state)
  (for/fold ([h (hash)]) ([r (in-list (resource-list (app-state-resources state)))])
    (define p (resource-path (app-state-resources state) (resource-id r)))
    (if p
        (hash-set h (filetree-normalize-path p) #t)
        h)))

;;; 行投影的输入：root + 展开集合 + 已打开集合。
;;; 三者都没变就复用上一帧的 rows —— 否则每帧都要重扫目录（每个 entry 若干次
;;; stat）、重建行、重建 document，行数一多就是几十毫秒一帧。
(define (projection-key state f)
  (list (app-state-root state)
        (sort (hash-keys (filetree-expanded f)) string<?)
        (sort (hash-keys (opened-paths state)) string<?)))

(define (sync-filetree! state engine)
  (define f (filetree-state state))
  (cond
    [(or (not f) (not (filetree-view f))) state]
    [else
     (define key (projection-key state f))
     (define cached? (equal? key (filetree-projection f)))
     (define rows
       (if cached?
           (filetree-rows f)
           (filetree-lines (app-state-root state)
                           (filetree-expanded f)
                           (opened-paths state)
                           dir-entries)))
     (define f0 (if cached? f (filetree-set-projection f key rows)))
     (define vid (filetree-view f0))
     ;; 键盘移动（cursor-dirty? = #t）用 state 的 cursor；否则以 view 的光标为准。
     ;; 列不限制在行首：普通 buffer 怎么动，文件树就怎么动（越界由 core clamp）。
     (define-values (line col)
       (if (filetree-cursor-dirty? f0)
           (values (filetree-cursor f0) 0)
           (values (or (engine-view-point-line engine vid) 0)
                   (or (engine-view-point-column engine vid) 0))))
     (engine-set-view-lines! engine vid
                             (map filetree-line-text rows)
                             (map filetree-line-face rows)
                             line
                             #:column col)
     ;; 写回镜像（engine 会 clamp；点击/滚动后以 view 为准）
     (define cursor (or (engine-view-point-line engine vid) line))
     (set-filetree-state state (filetree-sync-line f0 cursor))]))
