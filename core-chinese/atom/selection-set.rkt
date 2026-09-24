#lang racket

(require "point.rkt" "edit.rkt" "selection.rkt" rackunit)

;;; atom/selection-set.rkt —— 命名选区集
;;;
;;;   选区集 = 名称 ⊕ 选区列表 ⊕ 主导-索引
;;;
;;; 一组区间（多选区）+ 名字 + 一个 主导（「原来的单选区」）——就是插入/删除作用的**操作对象**。
;;; **纯值 + 代数**：core 不决定何时收敛；上层持有选区集、对它做插入/删除（经 编辑器 命令），
;;; 自己调用 选区集-清空 收敛回单个选区。
;;;
;;; 选区列表 始终规范化（排序 / 去重 / 重叠合并）；主导 用下标表达，跨规范化由
;;; 选区列表-主选区-索引 追踪（半开边界不歧义：插入符 不会被前一个区间吃掉）。
;;;
;;; 依赖：位置 / 编辑 / 选区 —— 不认识 窗口 / 文档。

(provide
 选区集?
 选区集-名称
 选区集-选区列表
 选区集-主导-索引
 选区集-打开
 选区集-规范化
 选区集-主导
 选区集-安装-主导
 选区集-添加
 选区集-移除
 选区集-映射
 选区集-清空
 选区集-映射-编辑
 选区集-推进-主导)

;;; ---------- 数据 ----------

(struct 选区集 (名称 选区列表 主导-索引) #:transparent)
;; 名称         : (or/c symbol? #f)               名字（“命名”）；#f = 匿名/已清除
;; 选区列表   : (nonempty-listof 选区)     已规范化
;; 主导-索引 : nat                              主导 在 选区列表 里的下标

;;; ---------- 构造 / 规范化 ----------
;; 主导-索引 是**输入** 选区列表 里的下标；规范化（排序/合并）后追到对应项。

(define (选区集-打开 名称 sels [主导-索引 0])
  (unless (pair? sels) (error '选区集-打开 "至少一个选区，得到 ~a" sels))
  (define idx0 (max 0 (min 主导-索引 (sub1 (length sels)))))
  (define 目标项 (list-ref sels idx0))
  (define 规范 (选区列表-规范化 sels))
  (选区集 名称 规范 (选区列表-主选区-索引 规范 目标项)))

(define (选区集-规范化 g)
  (选区集-打开 (选区集-名称 g)
              (选区集-选区列表 g)
              (选区集-主导-索引 g)))

;;; ---------- 读 ----------

;; 主导 选区**值**（“原来的单选区”）。
(define (选区集-主导 g)
  (list-ref (选区集-选区列表 g) (选区集-主导-索引 g)))

;;; ---------- 变更 ----------

;; 让集合中等于 s 的选区成为 主导（不在集合中则原样）。
(define (选区集-安装-主导 g s)
  (define 索引 (for/first ([x (in-list (选区集-选区列表 g))] [i (in-naturals)]
                          #:when (equal? x s)) i))
  (if 索引 (选区集 (选区集-名称 g) (选区集-选区列表 g) 索引) g))

;; 并集；主导 保持（新加的追加在后面，原 主导 下标仍有效）。
(define (选区集-添加 g sels)
  (选区集-打开 (选区集-名称 g)
              (append (选区集-选区列表 g) sels)
              (选区集-主导-索引 g)))

;; 差集；主导 尽量保持，删空则原样。
(define (选区集-移除 g 丢弃)
  (define sels (选区集-选区列表 g))
  (define 目标项 (选区集-主导 g))
  (define 保留 (remove* 丢弃 sels))
  (cond
    [(null? 保留) g]
    [else
     (define 索引 (or (for/first ([x (in-list 保留)] [i (in-naturals)]
                                 #:when (equal? x 目标项)) i)
                     0))
     (选区集-打开 (选区集-名称 g) 保留 索引)]))

;; 对每个选区施加 f（选区 → 选区）；主导 跟随。
(define (选区集-映射 g f)
  (选区集-打开 (选区集-名称 g)
              (map f (选区集-选区列表 g))
              (选区集-主导-索引 g)))

;;; ---------- 清除 / 编辑后重定位 ----------

;; 清除：收敛为**单个**选区（主导），名字丢弃。上层决定何时调用。
(define (选区集-清空 g)
  (选区集-打开 #f (list (选区集-主导 g)) 0))

;; 编辑后重定位（自由 语义）：每个选区端点过 描述集。
(define (选区集-映射-编辑 g 描述集)
  (选区集-打开 (选区集-名称 g)
              (for/list ([s (in-list (选区集-选区列表 g))])
                (for/fold ([s s]) ([d (in-list 描述集)]) (选区-映射-编辑 d s)))
              (选区集-主导-索引 g)))

;; 编辑后重定位（主导 语义）：每个选区坍缩到 头部 并前进到插入之后。
(define (选区集-推进-主导 g 描述集)
  (选区集-打开 (选区集-名称 g)
              (for/list ([s (in-list (选区集-选区列表 g))])
                (插入符 (编辑列表-映射-位置 描述集 (选区-头部 s))))
              (选区集-主导-索引 g)))

;;; ---------- 测试 ----------

(module+ test
  (define (P l c) (位置 l c))
  (define s1 (选区 (P 0 0) (P 0 3)))
  (define s2 (选区 (P 0 8) (P 0 11)))
  (define s3 (选区 (P 0 16) (P 0 19)))

  ;; 构造：规范化 + 主导 下标
  (define g (选区集-打开 'g (list s1 s2 s3) 1))
  (check-equal? (选区集-名称 g) 'g)
  (check-equal? (选区集-选区列表 g) (list s1 s2 s3))
  (check-equal? (选区集-主导 g) s2)
  (check-equal? (选区集-主导-索引 g) 1)

  ;; 重叠合并后 主导 追到包络
  (define g2 (选区集-打开 'x (list (选区 (P 0 0) (P 0 4)) (选区 (P 0 2) (P 0 6))) 1))
  (check-equal? (length (选区集-选区列表 g2)) 1)
  (check-equal? (选区集-主导 g2) (选区 (P 0 0) (P 0 6)))

  ;; 边界不歧义：[0,2) 与 插入符(2) 并存，leader=caret 不得归给 [0,2)
  (define gc (选区集-打开 'c (list (选区 (P 0 0) (P 0 2)) (插入符 (P 0 2))) 1))
  (check-equal? (选区集-主导 gc) (插入符 (P 0 2)))

  ;; 增 / 删 / 设 主导 / map；名字保持
  (check-equal? (选区集-选区列表 (选区集-添加 (选区集-打开 'g (list s1) 0) (list s2)))
                (list s1 s2))
  (check-equal? (选区集-名称 (选区集-添加 g (list s1))) 'g)
  (check-equal? (选区集-选区列表 (选区集-移除 g (list s2))) (list s1 s3))
  (check-equal? (选区集-主导 (选区集-安装-主导 g s3)) s3)
  (check-equal? (选区集-主导 (选区集-映射 (选区集-打开 'g (list s1 s2) 1)
                                         (lambda (s) (插入符 (选区-锚点 s)))))
                (插入符 (P 0 8)))

  ;; 清除：单个选区 = 主导，名字丢弃
  (define gc2 (选区集-清空 g))
  (check-false (选区集-名称 gc2))
  (check-equal? (选区集-选区列表 gc2) (list s2))
  (check-equal? (选区集-主导 gc2) s2)

  ;; 编辑后重定位：插入 "XX" 在位置 (0,4)；自由 平移，主导 前进
  (define dins (编辑-描述 (P 0 4) (P 0 4) "XX"))
  (check-equal? (map 选区-头部 (选区集-选区列表 (选区集-映射-编辑 g (list dins))))
                (list (P 0 3) (P 0 13) (P 0 21)))
  (check-equal? (选区集-主导 (选区集-推进-主导 g (list dins)))
                (插入符 (P 0 13)))

  (displayln "selection-set.rkt: all tests passed"))
