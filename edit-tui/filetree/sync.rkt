#lang racket

;;; edit-tui-rebuild/filetree/sync.rkt —— 文件树同步
;;;
;;; 每帧：
;;;   resource paths -> opened 集合
;;;   dir-entries + expanded -> 行
;;;   rows / cursor 写回 app-state.store['filetree]
;;;   同时把文本 / face / 光标写进 core view

(require "../core/skeleton.rkt"
         "../app/state.rkt"
         "slice.rkt"
         "model.rkt"
         "lines.rkt"
         "scan.rkt")

(provide sync-filetree!)

(define (opened-path-set state)
  (for/fold ([h (hash)]) ([r (in-list (resource-list (app-state-resources state)))])
    (define p (resource-path (app-state-resources state) (resource-id r)))
    (if p
        (hash-set h (resource-normalize-path p) #t)
        h)))

;;; 行投影的输入：root + 展开集合 + 已打开集合。
;;; 三者都没变就复用上一帧的 rows —— 否则每帧都要重扫目录（每个 entry 若干次
;;; stat）、重建行、重建 document，行数一多就是几十毫秒一帧。
;;; opened-path-set 只算一次，key 和 rows 共用。
(define (filetree-projection-key root expanded opened)
  (list root
        (sort (hash-keys expanded) string<?)
        (sort (hash-keys opened) string<?)))

;;; sync 的完整输入：view + rows 投影输入 + 期望光标。
;;; 这个 key 与 filetree.sync-key 相同，说明上一帧已经把同样内容写进 view，
;;; 本帧可以整段跳过（不 map rows、不碰 engine）。
(define (filetree-sync-input vid projection-key line col)
  (list vid projection-key line col))

(define (sync-filetree! state engine)
  (define f (filetree-of state))
  (cond
    [(or (not f) (not (filetree-view f))) state]
    [else
     (define store (app-state-resources state))
     (define root (resource-root store))
     (define expanded (filetree-expanded f))
     ;; opened 集合由 resource 版本决定：版本没变就不扫 resource-list。
     (define opened-revision (resource-opened-revision store))
     (define opened-changed?
       (not (equal? opened-revision (filetree-opened-revision f))))
     (define opened
       (if opened-changed?
           (opened-path-set state)
           (filetree-opened f)))
     (define f0
       (if opened-changed?
           (filetree-set-opened f opened opened-revision)
           f))
     (define projection-key (filetree-projection-key root expanded opened))
     (define vid (filetree-view f0))
     ;; 键盘移动（cursor-dirty? = #t）用 state 的 cursor；否则以 view 的光标为准。
     ;; 列不限制在行首：普通 buffer 怎么动，文件树就怎么动（越界由 core clamp）。
     (define-values (line col)
       (if (filetree-cursor-dirty? f0)
           (values (filetree-cursor f0) 0)
           (values (or (engine-view-point-line engine vid) 0)
                   (or (engine-view-point-column engine vid) 0))))
     (define sync-input (filetree-sync-input vid projection-key line col))
     (cond
       [(equal? sync-input (filetree-sync-key f0))
        (if opened-changed? (filetree-put state f0) state)]
       [else
        (define cached? (equal? projection-key (filetree-projection f0)))
        (define rows
          (if cached?
              (filetree-rows f0)
              (filetree-lines root expanded opened dir-entries)))
        (engine-set-view-lines! engine vid
                                (map filetree-line-text rows)
                                (map filetree-line-face rows)
                                line
                                #:column col)
        ;; 写回镜像（engine 会 clamp/scroll）；sync-key 用实际光标，
        ;; 下一帧从 view 读回同一个 key 就可以跳过。
        (define actual-line (or (engine-view-point-line engine vid) line))
        (define actual-col (or (engine-view-point-column engine vid) col))
        (define actual-key (filetree-sync-input vid projection-key actual-line actual-col))
        (filetree-put state
                      (filetree-set-sync f0 projection-key rows actual-key actual-line))])]))
