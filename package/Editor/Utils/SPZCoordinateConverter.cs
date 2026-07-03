// SPDX-License-Identifier: MIT

using Unity.Mathematics;

namespace GaussianSplatting.Editor.Utils
{
    public enum CoordinateSystem
    {
        Unspecified = 0,
        LDB = 1,
        RDB = 2,
        LUB = 3,
        RUB = 4,
        LDF = 5,
        RDF = 6,
        LUF = 7,
        RUF = 8, // Unity coordinate system
    }

    struct CoordinateConverter
    {
        public float3 flipP;
        public float3 flipQ;
        public float sh0;
        public float sh1;
        public float sh2;
        public float sh3;
        public float sh4;
        public float sh5;
        public float sh6;
        public float sh7;
        public float sh8;
        public float sh9;
        public float sh10;
        public float sh11;
        public float sh12;
        public float sh13;
        public float sh14;

        public static CoordinateConverter Create(CoordinateSystem from, CoordinateSystem to)
        {
            var fromIdx = (int)from - 1;
            var toIdx = (int)to - 1;
            var x = fromIdx < 0 || toIdx < 0 || ((fromIdx >> 0) & 1) == ((toIdx >> 0) & 1) ? 1.0f : -1.0f;
            var y = fromIdx < 0 || toIdx < 0 || ((fromIdx >> 1) & 1) == ((toIdx >> 1) & 1) ? 1.0f : -1.0f;
            var z = fromIdx < 0 || toIdx < 0 || ((fromIdx >> 2) & 1) == ((toIdx >> 2) & 1) ? 1.0f : -1.0f;

            return new CoordinateConverter
            {
                flipP = new float3(x, y, z),
                flipQ = new float3(y * z, x * z, x * y),
                sh0 = y,
                sh1 = z,
                sh2 = x,
                sh3 = x * y,
                sh4 = y * z,
                sh5 = 1.0f,
                sh6 = x * z,
                sh7 = 1.0f,
                sh8 = y,
                sh9 = x * y * z,
                sh10 = y,
                sh11 = z,
                sh12 = x,
                sh13 = z,
                sh14 = x,
            };
        }

        public float SHFlip(int idx)
        {
            return idx switch
            {
                0 => sh0,
                1 => sh1,
                2 => sh2,
                3 => sh3,
                4 => sh4,
                5 => sh5,
                6 => sh6,
                7 => sh7,
                8 => sh8,
                9 => sh9,
                10 => sh10,
                11 => sh11,
                12 => sh12,
                13 => sh13,
                14 => sh14,
                _ => 1.0f,
            };
        }
    }
}
