#lang racket

(require "../atom/point.rkt" "../atom/edit.rkt" "../atom/selection.rkt" "../atom/attr.rkt"
         "../doc/buffer.rkt" "../doc/document.rkt"
         "../viewport/window.rkt" "../viewport/layout.rkt"
         "../unit/history.rkt"
         "state.rkt" "write.rkt" "neutral.rkt" "program.rkt" "reaction.rkt" rackunit)

;;; platform/command.rkt —— 用户命令：主导 + 确保 + 账本
;;;
;;; 编辑原语是 program.rkt 的 编辑器-命令；这里只固定「用户编辑」的策略：
;;;   编辑器-视口-编辑 / 编辑器-编辑 = 编辑器-命令 + #:反应 '主导 + #:记录? '默认
;;; 导航与同步是 编辑器-视口-安装-窗口（裸写）+ 窗口-* + 编辑器-视口-跟随 的组合。
;;; 所有原语按 视口标识 定位；焦点 只是解析 视口标识 的糖。

(provide
 ;; 用户面原语（按 视口标识；不读也不改 焦点）
 编辑器-视口-编辑
 编辑器-视口-撤销
 编辑器-视口-重做
 编辑器-视口-左
 编辑器-视口-右
 编辑器-视口-上
 编辑器-视口-下
 编辑器-视口-行首
 编辑器-视口-末尾
 编辑器-视口-跳转
 编辑器-视口-滚动
 编辑器-视口-跟随
 ;; 焦点 糖
 编辑器-编辑
 编辑器-撤销
 编辑器-重做
 编辑器-左
 编辑器-右
 编辑器-上
 编辑器-下
 编辑器-行首
 编辑器-末尾
 编辑器-跳转
 编辑器-滚动
 编辑器-跟随)

;; 解析焦点 视口标识 —— 用户面唯一读 焦点 的地方。
(define (已聚焦-视口标识 ed) (视口-标识 (编辑器-已聚焦-视口 ed)))

;;; ---------- 编辑（指定 视口，主导 语义） ----------
;; 薄封装：策略全在 编辑器-命令 的参数里；这里只固定「用户编辑」的取值。

(define (编辑器-视口-编辑 ed 视口标识 操作)
  (编辑器-命令 ed 操作 #:视口 视口标识 #:反应 '主导 #:记录? '默认))

;;; ---------- 撤销 / 重做（指定 视口 所属 文档 的账本） ----------

;; 依次施加一串 变更（撤销/重放）；每个 变更 后把 视口标识 的视图 主导 到插入后。
;; 返回 (values 编辑器 生效文本描述集 生效属性描述集)。
;; 累积用 cons（末尾一次 append*），避免逐条 append 的 O(n²)。
(define (施加-变更-序列 ed 文档标识 视口标识 chs)
  (define-values (e* 文本集-反向 属性集-反向)
    (for/fold ([e ed] [文本集 '()] [属性集 '()]) ([字符 (in-list chs)])
      (define-values (e1 res) (编辑器-施加-变更 e 文档标识 字符 #:受信? #t))   ; 受信
      (cond
        [(not res) (values e1 文本集 属性集)]
        [else
         (define tds (变更-结果-已施加-文本集 res))
         (define ads (变更-结果-已施加-属性集 res))
         (define e2 (if (null? tds) e1 (编辑器-主导-视口 e1 视口标识 (编辑器-文档 e1 文档标识) tds)))
         (values e2 (cons tds 文本集) (cons ads 属性集))])))
  (values e* (append* (reverse 文本集-反向)) (append* (reverse 属性集-反向))))

(define (编辑器-视口-撤销 ed 视口标识)
  (define 文档标识 (编辑器-视口-文档-标识 ed 视口标识))
  (define-values (st h*) (历史-弹出-撤销 (编辑器-历史 ed 文档标识)))
  (cond
    [(not st) (values ed #f)]
    [else
     (define-values (ed* 文本集 属性集) (施加-变更-序列 ed 文档标识 视口标识 (步骤-撤销 st)))
     ;; 撤销后 主导 光标回到该步开始前，并 确保
     (define w* (窗口-确保-位置
                 (窗口-设置-位置 (视口-窗口 (编辑器-视口-引用 ed* 视口标识)) (步骤-前-位置 st))))
     (define ed** (编辑器-主导-窗口 ed* 视口标识 w*))
     (values (编辑器-安装-历史 ed** 文档标识 h*) (变更-报告 文本集 属性集))]))

(define (编辑器-视口-重做 ed 视口标识)
  (define 文档标识 (编辑器-视口-文档-标识 ed 视口标识))
  (define-values (st h*) (历史-弹出-重做 (编辑器-历史 ed 文档标识)))
  (cond
    [(not st) (values ed #f)]
    [else
     (define-values (ed* 文本集 属性集) (施加-变更-序列 ed 文档标识 视口标识 (步骤-重放 st)))
     (values (编辑器-安装-历史 ed* 文档标识 h*) (变更-报告 文本集 属性集))]))

;;; ---------- 导航（指定 视口；移动后 确保 + 跟随 镜像） ----------
;; 裸写用 编辑器-视口-安装-窗口（program.rkt），同步用 编辑器-视口-跟随；
;; 这里的 编辑器-视口-移动 是二者的组合，故不对外。

(define (编辑器-视口-移动 ed 视口标识 f)
  (define w* (窗口-确保-位置 (f (视口-窗口 (编辑器-视口-引用 ed 视口标识)))))
  (编辑器-主导-窗口 ed 视口标识 w*))

(define (编辑器-视口-左 ed 视口标识)  (编辑器-视口-移动 ed 视口标识 窗口-左))
(define (编辑器-视口-右 ed 视口标识) (编辑器-视口-移动 ed 视口标识 窗口-右))
(define (编辑器-视口-上 ed 视口标识)    (编辑器-视口-移动 ed 视口标识 窗口-上))
(define (编辑器-视口-下 ed 视口标识)  (编辑器-视口-移动 ed 视口标识 窗口-下))
(define (编辑器-视口-行首 ed 视口标识)  (编辑器-视口-移动 ed 视口标识 窗口-行首))
(define (编辑器-视口-末尾 ed 视口标识)   (编辑器-视口-移动 ed 视口标识 窗口-末尾))
(define (编辑器-视口-跳转 ed 视口标识 p)
  (编辑器-视口-移动 ed 视口标识 (lambda (w) (窗口-设置-位置 w p))))
(define (编辑器-视口-滚动 ed 视口标识 增量)
  (编辑器-主导-窗口 ed 视口标识
                        (窗口-滚动 (视口-窗口 (编辑器-视口-引用 ed 视口标识)) 增量)))

;;; ---------- 同步（显式、可组合） ----------
;; 以 视口标识 的当前 窗口 为准，镜像同 文档 的 跟随 视口，以及同 链接 的成员（可跨 文档）；
;; 视口标识 自身不动。与裸写组合：先 编辑器-视口-安装-窗口，再 编辑器-视口-跟随。

(define (编辑器-视口-跟随 ed 视口标识)
  (编辑器-主导-窗口 ed 视口标识 (视口-窗口 (编辑器-视口-引用 ed 视口标识))))
(define (编辑器-跟随 ed) (编辑器-视口-跟随 ed (已聚焦-视口标识 ed)))

;;; ---------- 焦点 糖（用户面便捷；程序面请用上面的 编辑器-视口-*） ----------

(define (编辑器-编辑 ed 操作)        (编辑器-视口-编辑 ed (已聚焦-视口标识 ed) 操作))
(define (编辑器-撤销 ed)           (编辑器-视口-撤销 ed (已聚焦-视口标识 ed)))
(define (编辑器-重做 ed)           (编辑器-视口-重做 ed (已聚焦-视口标识 ed)))
(define (编辑器-左 ed)           (编辑器-视口-左 ed (已聚焦-视口标识 ed)))
(define (编辑器-右 ed)          (编辑器-视口-右 ed (已聚焦-视口标识 ed)))
(define (编辑器-上 ed)             (编辑器-视口-上 ed (已聚焦-视口标识 ed)))
(define (编辑器-下 ed)           (编辑器-视口-下 ed (已聚焦-视口标识 ed)))
(define (编辑器-行首 ed)           (编辑器-视口-行首 ed (已聚焦-视口标识 ed)))
(define (编辑器-末尾 ed)            (编辑器-视口-末尾 ed (已聚焦-视口标识 ed)))
(define (编辑器-跳转 ed p)         (编辑器-视口-跳转 ed (已聚焦-视口标识 ed) p))
(define (编辑器-滚动 ed 增量)   (编辑器-视口-滚动 ed (已聚焦-视口标识 ed) 增量))

;;; ---------- 测试 ----------

(module+ test
  ;; 单 缓冲 编辑闭环 + 撤销/重做
  (define e0 (编辑器-打开 ""))
  (define-values (e1 r1) (编辑器-编辑 e0 (编辑-插入-字符 #\a)))
  (define-values (e2 _u1) (编辑器-编辑 e1 (编辑-插入-字符 #\b)))
  (define-values (e3 _u2) (编辑器-编辑 e2 (编辑-插入-字符 #\c)))
  (check-equal? (编辑器-文档->字符串 e3 0) "abc")
  (check-equal? (变更-报告-首-行 r1) 0)
  (check-equal? (编辑器-文档-撤销-深度 e3 0) 1)          ; 打字连续段并成 1 步
  (define-values (u1 r-u3) (编辑器-撤销 e3))
  (check-equal? (编辑器-文档->字符串 u1 0) "")
  (check-equal? (编辑器-位置 u1) (位置 0 0))
  ;; 撤销报告：施加顺序的 撤销-描述集
  (check-equal? (变更-报告-文本集 r-u3)
                (list (编辑-描述 (位置 0 2) (位置 0 3) "")
                      (编辑-描述 (位置 0 1) (位置 0 2) "")
                      (编辑-描述 (位置 0 0) (位置 0 1) "")))
  (define-values (r1b r-u4) (编辑器-重做 u1))
  (check-equal? (编辑器-文档->字符串 r1b 0) "abc")
  (check-equal? (变更-报告-文本集 r-u4)
                (list (编辑-描述 (位置 0 0) (位置 0 0) "a")
                      (编辑-描述 (位置 0 1) (位置 0 1) "b")
                      (编辑-描述 (位置 0 2) (位置 0 2) "c")))

  ;; 多 文档：各自独立文本 / 账本
  (define ed (编辑器-打开 "AAA"))
  (define-values (ed2 bid1) (编辑器-打开-文档 ed "BBB" #:名称 "b.txt" #:焦点? #t))
  (check-equal? (编辑器-文档-标识 ed2) bid1)
  (define-values (ed3 _u5) (编辑器-编辑 ed2 (编辑-插入 "x")))
  (check-equal? (编辑器-文档->字符串 ed3 bid1) "xBBB")
  (check-equal? (编辑器-文档->字符串 ed3 0) "AAA")
  (check-true (编辑器-文档-可撤销? ed3 bid1))
  (check-false (编辑器-文档-可撤销? ed3 0))

  ;; 多视图同 文档：自由 映射、跟随 镜像
  (define m0 (编辑器-打开 "l0\nl1\nl2\nl3\nl4\nl5\nl6"))
  (define-values (m1 v0) (编辑器-添加-视口 m0 0 3 10))         ; 默认不抢焦点：仍停在 视口 0
  (define m2 (编辑器-焦点-视口 (编辑器-视口-设置-同步 m1 v0 '跟随) 0))
  (define m3 (编辑器-跳转 m2 (位置 0 0)))
  (define-values (m4 _u6) (编辑器-编辑 m3 (编辑-插入 "XY")))
  (check-equal? (编辑器-文档->字符串 m4 0) "XYl0\nl1\nl2\nl3\nl4\nl5\nl6")
  (check-equal? (编辑器-位置 m4) (位置 0 2))
  (check-equal? (编辑器-视口-位置 m4 v0) (位置 0 2))
  (check-eq? (编辑器-文档-缓冲 m4 0) (窗口-缓冲 (视口-窗口 (编辑器-视口-引用 m4 v0))))

  ;; 同步契约：跟随 镜像 主导 视口；自由 钉住；别的 缓冲 不动
  (define g0 (编辑器-打开 (string-join (map number->string (range 30)) "\n") 5 20))
  (define-values (g1 vfree) (编辑器-添加-视口 g0 0 5 20 #:焦点? #f))
  (define-values (g2 vfollow) (编辑器-添加-视口 g1 0 5 20 #:同步 '跟随 #:焦点? #f))
  (define-values (g3 other) (编辑器-打开-文档 g2 "OTHER" #:名称 "other"))
  (define g4 (编辑器-焦点-视口 g3 0))
  (define g5 (编辑器-跳转 g4 (位置 20 0)))
  (check-equal? (编辑器-顶行 g5) 16)
  (check-equal? (编辑器-视口-顶行 g5 vfree) 0)
  (check-equal? (编辑器-视口-顶行 g5 vfollow) (编辑器-顶行 g5))
  (define-values (g6 _u9) (编辑器-编辑 g5 (编辑-插入-字符 #\X)))
  (check-equal? (编辑器-文档->字符串 g6 other) "OTHER")
  (check-equal? (编辑器-视口-顶行 g6 vfollow) (编辑器-视口-顶行 g6 0))
  (check-eq? (编辑器-文档-缓冲 g6 0) (窗口-缓冲 (视口-窗口 (编辑器-视口-引用 g6 vfollow))))

  ;; 显式 视口标识 的用户语义：不抢焦点，只作用目标 视口
  (define p0 (编辑器-打开 "l0\nl1\nl2\nl3\nl4\nl5\nl6"))
  (define-values (p1 pv) (编辑器-添加-视口 p0 0 3 10 #:焦点? #f))
  (define p2 (编辑器-视口-跳转 p1 pv (位置 3 0)))
  (check-equal? (编辑器-视口-位置 p2 pv) (位置 3 0))
  (check-equal? (编辑器-位置 p2) (位置 0 0))              ; 焦点 视口 光标不动
  (define-values (p3 _r) (编辑器-视口-编辑 p2 pv (编辑-插入 "X")))
  (check-equal? (编辑器-文档->字符串 p3 0) "l0\nl1\nl2\nXl3\nl4\nl5\nl6")
  (check-equal? (编辑器-位置 p3) (位置 0 0))
  (check-true (编辑器-文档-可撤销? p3 0))
  (define-values (p4 _r2) (编辑器-视口-撤销 p3 pv))
  (check-equal? (编辑器-文档->字符串 p4 0) "l0\nl1\nl2\nl3\nl4\nl5\nl6")
  (define p5 (编辑器-视口-滚动 p4 pv 2))
  (check-equal? (编辑器-视口-顶行 p5 0) 0)              ; 焦点 视口 视口不动

  ;; 多光标：一组选区，一次替换全部；整批记一步
  (define mc0 (编辑器-打开 "foo bar foo"))
  (define mc1 (编辑器-设置-选区列表 mc0 (list (选区 (位置 0 0) (位置 0 3))
                                               (选区 (位置 0 8) (位置 0 11)))))
  (check-equal? (length (编辑器-选区列表 mc1)) 2)
  (define-values (mc2 _r-mc) (编辑器-编辑 mc1 (编辑-插入 "XX")))
  (check-equal? (编辑器-文档->字符串 mc2 0) "XX bar XX")
  (check-equal? (编辑器-文档-撤销-深度 mc2 0) 1)                 ; 整批一步
  (check-equal? (length (编辑器-选区列表 mc2)) 2)          ; 两选区各自映射
  (define-values (mc3 _u-mc) (编辑器-撤销 mc2))
  (check-equal? (编辑器-文档->字符串 mc3 0) "foo bar foo")

  ;; 多光标退格：每个光标删各自前一个字符（选区为空时）
  (define mc4 (编辑器-设置-选区列表 (编辑器-打开 "abc")
                                     (list (选区 (位置 0 1) (位置 0 1))
                                           (选区 (位置 0 3) (位置 0 3)))))
  (define-values (mc5 _r5) (编辑器-编辑 mc4 (编辑-退格)))
  (check-equal? (编辑器-文档->字符串 mc5 0) "b")

  ;; 跨行选区 + 边界光标：描述 重叠 → 合并重算，不崩（回归）
  (define oc (编辑器-设置-选区列表 (编辑器-打开 "abc\ndef\nghi")
                                    (list (选区 (位置 0 0) (位置 1 0)) (插入符 (位置 1 0)))))
  (check-equal? (length (编辑器-选区列表 oc)) 2)
  (define-values (oc1 _oc) (编辑器-编辑 oc (编辑-退格)))
  (check-equal? (编辑器-文档->字符串 oc1 0) "def\nghi")
  ;; 前向删除同边界情形
  (define od (编辑器-设置-选区列表 (编辑器-打开 "abc\ndef")
                                    (list (插入符 (位置 0 0)) (选区 (位置 0 0) (位置 0 2)))))
  (define-values (od1 _od) (编辑器-编辑 od (编辑-删除)))
  (check-equal? (编辑器-文档->字符串 od1 0) "c\ndef")

  ;; 编辑原语 编辑器-命令：策略是参数
  (define ec0 (编辑器-打开 "abcdef"))
  ;;   默认：焦点 视口 的选区 + 反应 'none；#:记录? '默认 → 跟随 文档 策略（这里 #:历史? #t）
  (define-values (ec1 _ec-r1) (编辑器-命令 ec0 (编辑-插入 "X")))
  (check-equal? (编辑器-文档->字符串 ec1 0) "Xabcdef")
  (check-equal? (编辑器-位置 ec1) (位置 0 0))          ; none：光标不动
  (check-true (编辑器-文档-可撤销? ec1))                    ; 默认跟随 文档
  ;;   #:记录? #f：显式不记账
  (define-values (ec1n _ec1nr) (编辑器-命令 ec0 (编辑-插入 "X") #:记录? #f))
  (check-false (编辑器-文档-可撤销? ec1n))
  ;;   显式 #:选区：程序化定位
  (define-values (ec2 _ec-r2) (编辑器-命令 ec0 (编辑-插入 "Y")
                                           #:选区 (list (插入符 (位置 0 3)))))
  (check-equal? (编辑器-文档->字符串 ec2 0) "abcYdef")
  ;;   显式 #:反应 '主导 + #:记录?：用户编辑语义
  (define-values (ec3 _ec-r3) (编辑器-命令 ec0 (编辑-插入 "X") #:反应 '主导 #:记录? #t))
  (check-equal? (编辑器-位置 ec3) (位置 0 1))          ; 主导：光标推进到插入后
  (check-true (编辑器-文档-可撤销? ec3))
  ;;   显式 #:受信? #t：绕 只读
  (define-values (ecr _ecr-r) (编辑器-文档-安装-属性 (编辑器-打开 "abc") 0 只读键 0 0 3 #t))
  (define-values (ecr1 rcr1) (编辑器-命令 ecr (编辑-插入-字符 #\X)
                                             #:选区 (list (插入符 (位置 0 1)))))
  (check-false rcr1)
  (check-equal? (编辑器-文档->字符串 ecr1 0) "abc")
  (define-values (ecr2 _ec-rcr2) (编辑器-命令 ecr (编辑-插入-字符 #\X)
                                              #:选区 (list (插入符 (位置 0 1))) #:受信? #t))
  (check-equal? (编辑器-文档->字符串 ecr2 0) "aXbc")

  ;; 显式同步：裸写不同步；编辑器-跟随 才把 跟随 视口 镜像到 主导 的 窗口
  ;; （主导 须光标可见：重基准-跟随 会按 镜像 后的光标重新 确保）
  (define f0 (编辑器-打开 "l0\nl1\nl2\nl3\nl4\nl5" 3 10))
  (define-values (f1 fv) (编辑器-添加-视口 f0 0 3 10 #:同步 '跟随))
  (define f2 (编辑器-焦点-视口 f1 0))
  (define w* (窗口-设置-顶行 (窗口-设置-位置 (编辑器-窗口 f2) (位置 5 0)) 3))
  (define f3 (编辑器-安装-窗口 f2 w*))
  (check-equal? (编辑器-视口-顶行 f3 fv) 0)                  ; 裸写不同步
  (check-equal? (编辑器-视口-顶行 (编辑器-跟随 f3) fv) 3)  ; 跟随 后镜像

  ;; 滚动同步：主导 把光标滚出视口时，跟随 视口必须**字面**跟随（不得被 follower 光标拉回）
  (define s0 (编辑器-打开 (string-join (for/list ([i (in-range 20)]) (format "l~a" i)) "\n") 3 10))
  (define-values (s1 sv) (编辑器-添加-视口 s0 0 3 10 #:同步 '跟随 #:焦点? #f))
  (define s2 (编辑器-焦点-视口 s1 0))            ; 光标在 (0,0)，即视口首行
  (define s3 (编辑器-视口-滚动 s2 0 1))         ; 视口下滚一行，光标滚到视口外
  (check-equal? (编辑器-视口-顶行 s3 0) 1)
  (check-equal? (编辑器-视口-顶行 s3 sv) 1)   ; 旧实现被 确保 拉回 0，差一行
  (check-equal? (编辑器-视口-位置 s3 sv) (位置 0 0))
  (define s4 (编辑器-视口-滚动 s3 0 1))
  (check-equal? (编辑器-视口-顶行 s4 sv) 2)   ; 继续滚仍逐行对齐
  ;; 滚回
  (define s5 (编辑器-视口-滚动 s4 0 -1))
  (check-equal? (编辑器-视口-顶行 s5 sv) 1)
  (check-equal? (编辑器-视口-顶行 s5 0) 1)

  ;; 文本 + 属性一条命令、一步撤销：撤销要把属性一起正确地回退
  (define ba0 (编辑器-打开 "abc"))
  (define-values (ba1 _ba-r)
    (编辑器-命令 ba0 (编辑-插入 "X")
                    #:选区 (list (插入符 (位置 0 1)))
                    #:属性集 (lambda (_ed _bid 文本集)
                              (for/list ([d (in-list 文本集)])
                                (属性-设置 (编辑-描述-起点 d) (编辑描述-之后的-位置 d)
                                          只读键 #t)))
                    #:反应 '主导 #:记录? #t))
  (check-equal? (编辑器-文档->字符串 ba1 0) "aXbc")
  (check-equal? (编辑器-文档-属性集-键-片段集 ba1 0 0 只读键) (list (list 1 2 #t)))
  (check-equal? (编辑器-文档-撤销-深度 ba1 0) 1)
  (define-values (ba2 _ba-u) (编辑器-撤销 ba1))
  (check-equal? (编辑器-文档->字符串 ba2 0) "abc")
  (check-false (属性-只读? (编辑器-文档-属性集-在 ba2 0 (位置 0 1))))
  ;; 重做也要把文本 + 属性恢复
  (define-values (ba3 _ba-r2) (编辑器-重做 ba2))
  (check-equal? (编辑器-文档->字符串 ba3 0) "aXbc")
  (check-equal? (编辑器-文档-属性集-键-片段集 ba3 0 0 只读键) (list (list 1 2 #t)))

  ;; 删除带属性的文本再撤销：属性不得丢失（旧实现的回归点）
  (define br0 (编辑器-打开 "abc"))
  (define-values (br1 _br-r) (编辑器-文档-施加-属性集 br0 0 (list (属性-设置 (位置 0 0) (位置 0 3) 只读键 #t))))
  (define br2 (编辑器-设置-选区列表 br1 (list (选区 (位置 0 1) (位置 0 2)))))
  (define-values (br3 _br-e) (编辑器-命令 br2 (编辑-退格) #:受信? #t #:反应 '主导 #:记录? #t))
  (check-equal? (编辑器-文档->字符串 br3 0) "ac")
  (define-values (br4 _br-u) (编辑器-撤销 br3))
  (check-equal? (编辑器-文档->字符串 br4 0) "abc")
  (check-equal? (编辑器-文档-属性集-键-片段集 br4 0 0 只读键) (list (list 0 3 #t)))

  ;; 跨 文档 视口同步（行数相同 → 行恒等）
  (define lk0 (编辑器-打开 (string-join (for/list ([i (in-range 8)]) (format "l~a" i)) "\n") 3 10 #:名称 "A"))
  (define-values (lk1 vidB) (编辑器-打开-文档
                             lk0 (string-join (for/list ([i (in-range 8)]) (format "m~a" i)) "\n")
                             3 10 #:名称 "B" #:焦点? #f))
  (check-false (编辑器-视口-链接 lk1 0))
  (define lk2 (编辑器-链接-视口列表 lk1 '对 (list 0 vidB)))
  (check-equal? (编辑器-视口-链接 lk2 0) '对)
  (check-equal? (编辑器-视口-链接 lk2 vidB) '对)
  (check-equal? (编辑器-链接列表 lk2) '(对))
  (define lk3 (编辑器-视口-跳转 lk2 0 (位置 5 0)))
  (check-equal? (编辑器-视口-顶行 lk3 0) 3)      ; 确保：位置 5 → 顶行 3
  (check-equal? (编辑器-视口-顶行 lk3 vidB) 3)   ; 行固定 → 3
  (define lk4 (编辑器-视口-跳转 lk3 0 (位置 0 0)))
  (check-equal? (编辑器-视口-顶行 lk4 vidB) 0)
  ;; 解链后不再跟
  (define lk5 (编辑器-视口-解除链接 lk4 vidB))
  (check-false (编辑器-视口-链接 lk5 vidB))
  (define lk6 (编辑器-视口-跳转 lk5 0 (位置 5 0)))
  (check-equal? (编辑器-视口-顶行 lk6 vidB) 0)   ; 已解链，不动

  ;; 目标更短 → 行夹到最近
  (define sk0 (编辑器-打开 (string-join (for/list ([i (in-range 8)]) (format "l~a" i)) "\n") 3 10 #:名称 "A"))
  (define-values (sk1 vidS) (编辑器-打开-文档 sk0 "m0\nm1\nm2\nm3" 3 10 #:名称 "S" #:焦点? #f))
  (define sk2 (编辑器-链接-视口列表 sk1 '短 (list 0 vidS)))
  (define sk3 (编辑器-视口-跳转 sk2 0 (位置 5 0)))
  (check-equal? (编辑器-视口-顶行 sk3 0) 3)
  (check-equal? (编辑器-视口-顶行 sk3 vidS) 1)   ; 3 → 最近末页（最大-top=1）

  ;; 列按比例：A line0 宽 8、B line0 宽 2；A 左列 4 → B 左列 1（4/8*2）
  (define ck0 (编辑器-打开 "abcdefgh\nzzzz" 3 20 #:名称 "A"))
  (define-values (ck1 vidC) (编辑器-打开-文档 ck0 "xy\nzzzz" 3 20 #:名称 "C" #:焦点? #f))
  (define ck2 (编辑器-链接-视口列表 ck1 '列 (list 0 vidC)))
  (define ck3 (编辑器-视口-设置-左列 ck2 0 4))
  (define ck4 (编辑器-视口-跟随 ck3 0))
  (check-equal? (编辑器-视口-左列 ck4 0) 4)
  (check-equal? (编辑器-视口-左列 ck4 vidC) 1)

  ;; 折行 follower：主导 裁剪 滚到列 6 → follower（宽 4）的 顶段 = 1
  (define wk0 (编辑器-打开 "abcdefgh" 3 20 #:名称 "A"))
  (define-values (wk1 vidW) (编辑器-打开-文档 wk0 "abcdefgh" 3 4 #:名称 "W" #:焦点? #f))
  (define wk2 (编辑器-视口-设置-模式 wk1 vidW '折行))
  (define wk3 (编辑器-链接-视口列表 wk2 'wr (list 0 vidW)))
  (define wk4 (编辑器-视口-跟随 (编辑器-视口-设置-左列 wk3 0 6) 0))
  (check-equal? (编辑器-视口-顶段 wk4 vidW) 1)

  ;; 同步链接会把成员光标也带过编辑：同 文档 的两个 视口 链接后，
  ;; 在 0 编辑时成员 slV 的选区也必须 重基准（不能停在旧坐标）。
  (define sl0 (编辑器-打开 "l0\nl1\nl2" 3 10 #:名称 "S"))
  (define-values (sl1 slV) (编辑器-添加-视口 sl0 0 3 10 #:焦点? #f))
  (define sl2 (编辑器-链接-视口列表 sl1 '相同 (list 0 slV)))
  (define sl3 (编辑器-视口-跳转 sl2 slV (位置 0 1)))
  (define-values (sl4 _slr) (编辑器-视口-编辑 sl3 0 (编辑-插入 "XX")))
  (check-equal? (编辑器-视口-位置 sl4 slV) (位置 0 3))   ; (0,1) 随编辑映射到 (0,3)

  ;; 编辑器-链接-视口列表 对不存在的 视口标识 报错，不静默忽略
  (check-exn exn:fail? (lambda () (编辑器-链接-视口列表 sl0 'x (list 0 999))))

  ;; 加链即对齐：参考成员 = 焦点 视口（此处焦点 = A/视口 0）
  (define al0 (编辑器-打开 "l0\nl1\nl2\nl3\nl4\nl5" 3 10 #:名称 "A"))
  (define-values (al1 vidAB) (编辑器-打开-文档 al0 "m0\nm1\nm2\nm3\nm4\nm5" 3 10 #:名称 "B" #:焦点? #f))
  (define al2 (编辑器-视口-设置-顶行 al1 0 3))            ; A top=3，B top=0
  (define al3 (编辑器-链接-视口列表 al2 'al (list 0 vidAB)))
  (check-equal? (编辑器-视口-顶行 al3 vidAB) 3)          ; B 对齐到焦点 A
  ;; 焦点在 B 时，以 B 为基准：A 被拉到 B 的位置
  (define al5 (编辑器-焦点-视口 al2 vidAB))
  (define al6 (编辑器-链接-视口列表 al5 'al2 (list 0 vidAB)))
  (check-equal? (编辑器-视口-顶行 al6 0) 0)
  ;; #:从 显式指定基准（视图时）：A 为基准 → B 跟到 3
  (define al7 (编辑器-链接-视口列表 al5 'al3 (list 0 vidAB) #:从 0))
  (check-equal? (编辑器-视口-顶行 al7 vidAB) 3)
  ;; #:对齐? #f：只设成员，视口不动
  (define al4 (编辑器-链接-视口列表 (编辑器-视口-设置-顶行 al1 0 3) 'al4 (list 0 vidAB) #:对齐? #f))
  (check-equal? (编辑器-视口-顶行 al4 vidAB) 0)
  ;; 单成员组：对齐即恒等，不报错
  (check-equal? (编辑器-视口-顶行 (编辑器-链接-视口列表 al2 '单独 (list vidAB)) vidAB) 0)
  ;; 链接 类型校验（符号 / #f）
  (check-exn exn:fail? (lambda () (编辑器-视口-设置-链接 al1 0 "bad")))
  (check-exn exn:fail? (lambda () (编辑器-链接-视口列表 al1 "bad" (list 0))))
  (check-exn exn:fail? (lambda () (编辑器-添加-视口 al1 0 3 10 #:链接 "bad")))

  (displayln "command.rkt: all tests passed"))
