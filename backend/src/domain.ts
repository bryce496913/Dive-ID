import { z } from "zod";

export const contextSchema = z
  .object({
    region: z.string().trim().max(200).nullable().optional(),
    waterType: z
      .enum(["saltwater", "freshwater", "brackish", "unknown"])
      .nullable()
      .optional(),
    approximateDepthMeters: z
      .number()
      .finite()
      .min(0)
      .max(12000)
      .nullable()
      .optional(),
    habitat: z.string().trim().max(300).nullable().optional(),
    approximateSize: z.string().trim().max(100).nullable().optional(),
    behavior: z.string().trim().max(300).nullable().optional(),
    observedAt: z.string().datetime().nullable().optional(),
  })
  .strict();

export const requestSchema = (maximum: number) =>
  z
    .object({
      requestId: z.string().uuid(),
      description: z
        .string()
        .transform((value) => value.trim())
        .pipe(
          z
            .string()
            .min(5, "DESCRIPTION_TOO_SHORT")
            .max(maximum, "DESCRIPTION_TOO_LONG"),
        ),
      context: contextSchema.optional(),
    })
    .strict();

export const providerMatchSchema = z
  .object({
    rank: z.number().int().min(1).max(100),
    commonName: z.string().trim().min(1).max(120),
    scientificName: z.string().trim().max(160),
    taxonomicResolution: z.enum(["species", "genus", "family", "group"]),
    confidenceCategory: z.enum(["strong", "good", "possible", "weak"]),
    matchScore: z.number().min(0).max(1).nullable(),
    explanation: z.string().trim().min(1).max(1000),
    distinguishingFeatures: z
      .array(z.string().trim().min(1).max(240))
      .min(1)
      .max(8),
    habitat: z.string().trim().min(1).max(500),
    geographicRange: z.string().trim().min(1).max(500),
    cautions: z.array(z.string().trim().min(1).max(300)).max(5),
  })
  .strict();
export const providerResultSchema = z
  .object({ matches: z.array(providerMatchSchema).max(20) })
  .strict();
export type DescriptionIdentificationRequest = z.infer<
  ReturnType<typeof requestSchema>
>;
export type ProviderResult = z.infer<typeof providerResultSchema>;

export type PublicMatch = z.infer<typeof providerMatchSchema> & {
  speciesId: string;
};
export interface IdentificationResponse {
  requestId: string;
  matches: PublicMatch[];
  disclaimer: string;
  generatedAt: string;
  modelVersion: string;
}
