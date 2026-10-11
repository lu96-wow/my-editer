#lang racket

;;; edit3/plugins/demo.rkt —— 示例插件（演示插件契约：op / panel / region / key-table / boot）
;;;
;;; 它做四件事：
;;;   · 贡献一个原语 demo-bump（把 feature 'demo-count 加一）；
;;;   · 贡献一个面板 *demo*，内容读 feature 'demo-count；
;;;   · 贡献一个区域 demo（贴主区右侧，成员 *demo*）；
;;;   · 贡献两个键：M-y 递增、M-u 显隐区域；boot 初始化计数。
;;; 默认不启用（config/plugins.rkt）；测试或用户显式启用。

(require "../core/extension.rkt")

(provide demo-plugin)

(define (demo-content st _v)
  (values (format "demo plugin\ncount: ~a\nopened: ~a\nM-y bump\nM-u toggle region"
                  (feature-ref st 'demo-count 0)
                  (feature-ref st 'demo-opened "-"))
          '()))

(define (demo-bump _ctx st _ev _args)
  (values (feature-set st 'demo-count (add1 (feature-ref st 'demo-count 0))) '()))

(define demo-plugin
  (make-plugin
   #:name 'demo
   #:ops (list (cons 'demo-bump demo-bump))
   #:panels (list (panel-spec "*demo*" #f demo-content))
   #:regions (list (region 'demo 'right 24 (list "*demo*") 'main))
   #:key-tables (list '(((key y alt) always (demo-bump))
                        ((key u alt) always (region-toggle demo))))
   ;; 文档打开时匹配 .demo 文件：给该 document 挂一张键表（M-g 递增），并跑 on-open。
   #:doc-key-matchers (list (cons '(ext "demo")
                                  '(((key g alt) always (demo-bump)))))
   #:on-open (lambda (st _did path) (feature-set st 'demo-opened (format "~a" path)))
   #:boot (lambda (st) (feature-set st 'demo-count 0))))
