#lang racket

;;; default-editor/panel.rkt —— 可组合窗格（generic window）
;;;
;;; 「窗格」是 default-editor 的组合单位：一个 id、自己的状态、以及四个回调
;;; （投影 / 尺寸 / 全量刷新 / 廉价同步）。shell 只通过本协议与窗格打交道 ——
;;; 于是前端 / 文件树 / 状态栏彼此不知道对方存在，唯一共享的是 layout（几何）与命令（输入）。
;;;
;;; 显隐（visible?）与文档生命周期无关：隐藏一个窗格只是不投影它，不关它的 document；
;;; 反之关闭 document 也不等于隐藏窗格。

(require "layout.rkt" rackunit)

(provide panel? panel-id panel-visible? panel-state
         panel-project panel-resize panel-refresh panel-sync
         panel-open panel-set-state panel-set-visible?)

(struct panel
  (id                        ; symbol
   visible?                  ; bool
   state                     ; any/c（窗格自己的状态）
   project-fn                ; (-> editor state screen)
   resize-fn                 ; (-> editor state rect (values editor state))
   refresh-fn                ; (-> editor state (values editor state))  全量（可能重扫外部资源）
   sync-fn)                  ; (-> editor state (values editor state))  廉价（只重算派生内容）
  #:transparent)

(define (panel-open id state
                    #:visible? [visible? #t]
                    #:project [project (lambda (_ed _st) (error 'panel "缺少 project 回调"))]
                    #:resize [resize (lambda (ed st _rect) (values ed st))]
                    #:refresh [refresh (lambda (ed st) (values ed st))]
                    #:sync [sync #f])
  (panel id (and visible? #t) state
         project resize refresh (or sync refresh)))

(define (panel-set-state p st) (struct-copy panel p [state st]))
(define (panel-set-visible? p on?) (struct-copy panel p [visible? (and on? #t)]))

(define (panel-project ed p) ((panel-project-fn p) ed (panel-state p)))

(define (panel-resize ed p r)
  (define-values (ed* st) ((panel-resize-fn p) ed (panel-state p) r))
  (values ed* (panel-set-state p st)))

(define (panel-refresh ed p)
  (define-values (ed* st) ((panel-refresh-fn p) ed (panel-state p)))
  (values ed* (panel-set-state p st)))

;; 廉价同步：编辑后只重算派生内容（不重扫 fs 之类）。
(define (panel-sync ed p)
  (define-values (ed* st) ((panel-sync-fn p) ed (panel-state p)))
  (values ed* (panel-set-state p st)))

;;; ---------- 测试 ----------

(module+ test
  (define log (box '()))
  (define (note! x) (set-box! log (cons x (unbox log))))
  (define p (panel-open 'x 0
                        #:project (lambda (_ed st) (list 'screen st))
                        #:resize (lambda (ed st r) (note! (list 'resize r)) (values ed (add1 st)))
                        #:refresh (lambda (ed st) (note! 'refresh) (values ed (add1 st)))
                        #:sync (lambda (ed st) (note! 'sync) (values ed (add1 st)))))
  (check-true (panel? p))
  (check-equal? (panel-id p) 'x)
  (check-true (panel-visible? p))
  (check-equal? (panel-state p) 0)
  (check-equal? (panel-project 'ed p) '(screen 0))
  ;; resize/refresh/sync 都返回新 panel 状态；原值不动
  (define-values (_e1 p1) (panel-resize 'ed p (rect 1 2 3 4)))
  (check-equal? (panel-state p1) 1)
  (check-equal? (panel-state p) 0)
  (define-values (_e2 p2) (panel-refresh 'ed p1))
  (check-equal? (panel-state p2) 2)
  (define-values (_e3 p3) (panel-sync 'ed p2))
  (check-equal? (panel-state p3) 3)
  ;; 无 sync 回调时，sync 退化为 refresh
  (define q (panel-open 'y 0 #:refresh (lambda (ed st) (note! 'q-refresh) (values ed (add1 st)))))
  (define-values (_e4 q1) (panel-sync 'ed q))
  (check-equal? (panel-state q1) 1)
  ;; 显隐是纯元数据
  (check-false (panel-visible? (panel-set-visible? p #f)))

  (displayln "panel.rkt: all tests passed"))
