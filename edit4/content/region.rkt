#lang racket

;;; edit4/content/region.rkt —— 面板槽（region）：一个窗口显示多个面板之一
;;;
;;; region = 边/尺寸/组合/当前成员/锚点/窗口/次序；成员互斥显示。
;;;   show   ：隐藏则新建窗格插入（anchor root 包整树；main 贴主编辑器窗），再绑定成员 vid；
;;;              root 区域插入后按 order 重建 root 链，保证嵌套顺序与声明一致（toggle 不漂）；
;;;   hide   ：摘掉窗格（记住当前宽度，show 时按它恢复）；
;;;   cycle/activate/focus：换成员 / 聚焦（隐藏则先显示）。
;;;
;;; 布局手术用 layout 的 insert-side / insert-adjacent / remove-leaf。

(provide region-commands region-ref region-show region-hide)

(require racket/list
         "../core/world.rkt" "../core/command.rkt"
         "../layout.rkt"
         "model.rkt" "adapter.rkt" "lifecycle.rkt")

(define (region-ref w rid) (hash-ref (content-regions (world-content w)) rid #f))

(define (region-set w rid r)
  (define c (world-content w))
  (world-set-content w (content-set-regions c (hash-set (content-regions c) rid r))))

(define (region-set-active w rid name)
  (define r (region-ref w rid))
  (if r (region-set w rid (struct-copy region r [active name])) w))

;; 当前窗口的 vid 换成 active 成员的 vid（已显示时）。
(define (region-sync w rid)
  (define c (world-content w))
  (define r (region-ref w rid))
  (cond
    [(not (and c r (region-wid r))) w]
    [else (define vid (content-panel-vid c (region-active r)))
          (if vid (world-set-content w (content-bind c (region-wid r) vid)) w)]))

;; 显示（隐藏则新建窗格插入）。
(define (region-show w rid)
  (define c (world-content w))
  (define r (region-ref w rid))
  (cond
    [(not (and c r)) w]
    [(region-wid r) (region-sync w rid)]
    [else
     (define lay (world-layout w))
     (define nid (fresh-id lay))
     (define sz (size (region-size r) #f))
     (define nleaf (leaf nid (cons 1 1)))
     (define nlay
       (case (region-anchor r)
         [(main) (define target (content-editor-window c lay))
                 (if target (insert-adjacent lay target (region-side r) sz nleaf)
                     (insert-side lay (region-side r) sz nleaf))]
         [else (insert-side lay (region-side r) sz nleaf)]))
     (define r* (struct-copy region r [wid nid]))
     (define w1 (region-sync (region-set (world-set-layout w nlay) rid r*) rid))
     ;; root 区域：按声明次序重建整条 root 链，避免「后 show 的变最外层」造成顺序漂移。
     (ensure-focus (if (eq? (region-anchor r) 'root) (rebuild-root-docks w1) w1))]))

;; 某个窗口在布局里的当前宽度意图（basis）——拖拽会更新它；找不到 → #f。
(define (window-basis-width lay id)
  (define p (path-of lay id))
  (and p (pair? p)
       (let ([parent (node-at lay (drop-right p 1))])
         (and (split? parent)
              (let ([c (list-ref (split-kids parent) (last p))])
                (size-basis (child-size c)))))))

;; 重建 root 区域链：所有 anchor=root 且已显示的区域，按 order 从内到外重新嵌套。
;; 保证任意 toggle 序列后嵌套顺序 = 声明顺序（初始尺寸/树内其它比例保持不变）。
(define (rebuild-root-docks w)
  (define regs (content-regions (world-content w)))
  (define roots
    (sort (for/list ([(id r) (in-hash regs)]
                     #:when (and (eq? (region-anchor r) 'root) (region-wid r)))
            (cons id r))
          < #:key (lambda (p) (region-order (cdr p)))))
  (cond
    [(null? roots) w]
    [else
     ;; 记下每个 root 区域当前的（可能被拖过的）尺寸
     (define sized
       (for/list ([p (in-list roots)])
         (define r (cdr p))
         (define cur (window-basis-width (world-layout w) (region-wid r)))
         (cons (car p) (struct-copy region r [size (or cur (region-size r))]))))
     ;; 全部摘掉（保留主区/树内其它结构不动）
     (define lay0
       (for/fold ([lay (world-layout w)]) ([p (in-list roots)])
         (remove-leaf lay (region-wid (cdr p)))))
     ;; 按 order 重新插入（先插的在最内层，与 boot 一致）
     (for/fold ([ww (world-set-layout w lay0)]) ([p (in-list sized)])
       (define id (car p))
       (define r (cdr p))
       (define lay (world-layout ww))
       (define nid (fresh-id lay))
       (define nlay (insert-side lay (region-side r) (size (region-size r) #f) (leaf nid (cons 1 1))))
       (region-sync (region-set (world-set-layout ww nlay) id (struct-copy region r [wid nid])) id))]))

;; 隐藏（摘掉窗格）。
(define (region-hide w rid)
  (define c (world-content w))
  (define r (region-ref w rid))
  (cond
    [(not (and c r (region-wid r))) w]
    [else
     (define wid (region-wid r))
     ;; 隐藏时记住当前的（可能被拖过的）宽度，显示回来照旧。
     (define cur (window-basis-width (world-layout w) wid))
     (define lay (remove-leaf (world-layout w) wid))
     (define r* (struct-copy region r [wid #f] [size (or cur (region-size r))]))
     (ensure-focus (region-set (world-set-layout w lay) rid r*))]))

;;; ---------- 命令 ----------

(define (h-region-cycle ctx w args)
  (define rid (car args))
  (define r (region-ref w rid))
  (cond
    [(not r) #f]
    [else
     (define ms (region-members r))
     (define cur (region-active r))
     (define i (or (for/first ([m (in-list ms)] [i (in-naturals)] #:when (equal? m cur)) i) 0))
     (define next (list-ref ms (modulo (add1 i) (length ms))))
     (cons (region-show (region-set-active w rid next) rid) '())]))

(define (h-region-activate ctx w args)
  (define rid (car args))
  (define name (cadr args))
  (cond [(not (region-ref w rid)) #f]
        [else (cons (region-show (region-set-active w rid name) rid) '())]))

(define (h-region-toggle ctx w args)
  (define rid (car args))
  (define r (region-ref w rid))
  (cond
    [(not r) #f]
    [else (cons (if (region-wid r) (region-hide w rid) (region-show w rid)) '())]))

(define (h-region-focus ctx w args)
  (define rid (car args))
  (define w* (region-show w rid))
  (define r (region-ref w* rid))
  (cond [(not (and r (region-wid r))) #f]
        [else (cons (world-set-focus w* (region-wid r)) '())]))

(define region-commands
  (make-command-registry
   (list (cons 'region-cycle h-region-cycle)
         (cons 'region-activate h-region-activate)
         (cons 'region-toggle h-region-toggle)
         (cons 'region-focus h-region-focus))))
